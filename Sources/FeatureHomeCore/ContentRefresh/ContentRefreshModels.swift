import Foundation

/// The topmost content surface that can be refreshed after the app or a page
/// becomes visible again.
public enum ContentRefreshSurfaceKind: String, Sendable, Equatable {
    case home
    case seriesDetail
    case episodeDetail
    case movieDetail
    case library
}

/// The work a surface should perform for a refresh request.
public enum ContentRefreshAction: String, Sendable, Equatable {
    case reloadHome
    case reloadSeriesContext
    case refreshWatchStateOnly
    case reloadDetail
    case none
}

/// Why a refresh is being considered.
public enum ContentRefreshReason: Sendable, Equatable {
    case foreground(awayFor: TimeInterval)
    case surfaceReturn(after: TimeInterval)
    case manual

    public var diagnosticTrigger: String {
        switch self {
        case .foreground: "foreground"
        case .surfaceReturn: "surface-return"
        case .manual: "manual"
        }
    }
}

/// Stable identity for a refresh surface. Account and item ids keep two
/// profiles, servers, or detail pages from consuming each other's requests.
public struct ContentRefreshSurfaceID: Hashable, Sendable {
    public let kind: ContentRefreshSurfaceKind
    public let accountID: String?
    public let itemID: String?

    public init(
        kind: ContentRefreshSurfaceKind,
        accountID: String? = nil,
        itemID: String? = nil
    ) {
        self.kind = kind
        self.accountID = accountID
        self.itemID = itemID
    }
}

/// A single structured refresh request. `generation` is monotonic so a view can
/// reject work that was superseded while it was still starting.
public struct ContentRefreshRequest: Equatable, Sendable {
    public let surface: ContentRefreshSurfaceID
    public let action: ContentRefreshAction
    public let reason: ContentRefreshReason
    public let generation: UInt64

    public init(
        surface: ContentRefreshSurfaceID,
        action: ContentRefreshAction,
        reason: ContentRefreshReason,
        generation: UInt64
    ) {
        self.surface = surface
        self.action = action
        self.reason = reason
        self.generation = generation
    }
}

/// Timing and action policy for one surface kind.
public struct ContentRefreshRule: Sendable, Equatable {
    public let foregroundAfter: TimeInterval
    public let surfaceReturnAfter: TimeInterval
    public let action: ContentRefreshAction

    public init(
        foregroundAfter: TimeInterval,
        surfaceReturnAfter: TimeInterval,
        action: ContentRefreshAction
    ) {
        self.foregroundAfter = max(0, foregroundAfter)
        self.surfaceReturnAfter = max(0, surfaceReturnAfter)
        self.action = action
    }
}

/// Platform-specific behavior. Views never own these numbers; changing tvOS or
/// iOS refresh timing is a one-line profile change.
public struct ContentRefreshProfile: Sendable, Equatable {
    public let home: ContentRefreshRule
    public let seriesDetail: ContentRefreshRule
    public let episodeDetail: ContentRefreshRule
    public let movieDetail: ContentRefreshRule
    public let library: ContentRefreshRule

    public init(
        home: ContentRefreshRule,
        seriesDetail: ContentRefreshRule,
        episodeDetail: ContentRefreshRule,
        movieDetail: ContentRefreshRule,
        library: ContentRefreshRule
    ) {
        self.home = home
        self.seriesDetail = seriesDetail
        self.episodeDetail = episodeDetail
        self.movieDetail = movieDetail
        self.library = library
    }

    public static let tvOS = ContentRefreshProfile(
        home: .init(
            foregroundAfter: 15,
            surfaceReturnAfter: 15,
            action: .reloadHome
        ),
        seriesDetail: .init(
            foregroundAfter: 300,
            surfaceReturnAfter: 300,
            action: .reloadSeriesContext
        ),
        episodeDetail: .init(
            foregroundAfter: 300,
            surfaceReturnAfter: 300,
            action: .refreshWatchStateOnly
        ),
        movieDetail: .init(
            foregroundAfter: 300,
            surfaceReturnAfter: 300,
            action: .refreshWatchStateOnly
        ),
        library: .init(
            foregroundAfter: 300,
            surfaceReturnAfter: 300,
            action: .none
        )
    )

    public static let iOS = ContentRefreshProfile.tvOS

    public func rule(for kind: ContentRefreshSurfaceKind) -> ContentRefreshRule {
        switch kind {
        case .home: home
        case .seriesDetail: seriesDetail
        case .episodeDetail: episodeDetail
        case .movieDetail: movieDetail
        case .library: library
        }
    }
}
