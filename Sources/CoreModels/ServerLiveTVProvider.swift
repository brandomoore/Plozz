import Foundation

/// Optional capability of an authenticated media provider. Discovery never
/// opens a tuner; playback is a separate, explicitly owned operation.
public protocol ServerLiveTVProviding: Sendable {
    /// Read an already committed lineup without authentication, refresh, guide requests, or tuning.
    func cachedLiveTVCatalog() async throws -> ServerLiveTVCatalogSnapshot?
    func liveTVAvailability() async throws -> ServerLiveTVAvailability
    /// Explicit source refreshes must not reuse an adapter's still-fresh channel catalog.
    func refreshLiveTVAvailability() async throws -> ServerLiveTVAvailability
    /// Complete already-started startup guide discovery after publishing saved channels.
    /// Returns nil when no capability update is needed; must not start another catalog download.
    func completeLiveTVGuideDiscovery() async throws -> Bool?
    func liveTVChannels() async throws -> [ServerLiveTVChannel]
    /// A window of at most 48 hours and 2,000 provider-local channel IDs.
    /// Prefer visible channels: some servers expose only per-channel/day EPG
    /// requests, rather than an efficient whole-lineup endpoint.
    func liveTVGuide(
        channelIDs: [String],
        from: Date,
        to: Date
    ) async throws -> [ServerLiveTVProgramme]
    /// Require revalidation on the next guide request, retaining usable saved listings.
    func invalidateLiveTVGuideCache() async
    func openLiveTVChannel(id: String) async throws -> any LiveTVStreamLease
}

public extension ServerLiveTVProviding {
    func cachedLiveTVCatalog() async throws -> ServerLiveTVCatalogSnapshot? { nil }
    func completeLiveTVGuideDiscovery() async throws -> Bool? { nil }
    func invalidateLiveTVGuideCache() async {}

    func refreshLiveTVAvailability() async throws -> ServerLiveTVAvailability {
        try await liveTVAvailability()
    }
}

/// Identifies one refresh across channel/window batches without sharing failures
/// with another refresh, account, or authorization. Providers own any scoped state.
public final class ServerLiveTVGuideRefreshScope: Sendable {
    @TaskLocal public static var current: ServerLiveTVGuideRefreshScope?

    public init() {}
}

/// Progress for the current stage, never an estimate of the entire guide job.
public struct ServerLiveTVGuideProgress: Equatable, Sendable {
    public enum Stage: Sendable {
        case downloading, readingGuide, preparingListings, saving, matching
    }

    public typealias Handler = @Sendable (ServerLiveTVGuideProgress) -> Void
    @TaskLocal public static var report: Handler?

    public let stage: Stage
    public let completed: Int
    public let total: Int?

    public init(stage: Stage, completed: Int = 0, total: Int? = nil) {
        self.stage = stage
        self.completed = max(0, completed)
        self.total = total.flatMap { $0 > 0 && $0 >= completed ? $0 : nil }
    }

    public var fractionCompleted: Double? {
        total.map { Double(completed) / Double($0) }
    }
}

/// Usable listings from an incomplete request. Consumers must retain the failure
/// and must not interpret omitted channels as successfully empty coverage.
public struct ServerLiveTVPartialGuideError: Error, Sendable {
    public let programmes: [ServerLiveTVProgramme]
    public let failure: any Error

    public init(programmes: [ServerLiveTVProgramme], failure: any Error) {
        self.programmes = programmes
        self.failure = failure
    }
}

public struct ServerLiveTVCatalogSnapshot: Sendable {
    public let channels: [ServerLiveTVChannel]
    public let supportsGuide: Bool

    public init(channels: [ServerLiveTVChannel], supportsGuide: Bool) {
        self.channels = channels
        self.supportsGuide = supportsGuide
    }
}

public struct ServerLiveTVAvailability: Equatable, Sendable {
    public enum Status: String, Sendable {
        case available
        case notConfigured
        case noChannels
        case permissionDenied
        case subscriptionRequired
        case serviceUnavailable
        case unsupportedAPI
        case unsupportedPlaybackMode
    }

    public let status: Status
    public let channelCount: Int
    /// Whether this source configuration exposes a guide lookup, not whether its EPG has listings.
    public let supportsGuide: Bool

    public var hasChannels: Bool { channelCount > 0 }
    public var supportsPlayback: Bool { status == .available && hasChannels }

    public init(status: Status, channelCount: Int = 0, supportsGuide: Bool = true) {
        self.status = status
        self.channelCount = max(0, channelCount)
        self.supportsGuide = supportsGuide
    }
}

/// Provider-local identity. The feature layer additionally namespaces this by
/// source/account, since two accounts may return identical channel identifiers.
public struct ServerLiveTVChannel: Hashable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let number: String?
    /// Credential-free artwork only; never a tuner or playback URL.
    public let imageURL: URL?
    public let isRadio: Bool
    public let groups: [String]
    public let currentProgramme: ServerLiveTVProgramme?

    public init(
        id: String,
        name: String,
        number: String? = nil,
        imageURL: URL? = nil,
        isRadio: Bool = false,
        groups: [String] = [],
        currentProgramme: ServerLiveTVProgramme? = nil
    ) {
        self.id = id
        self.name = name
        self.number = number
        self.imageURL = imageURL
        self.isRadio = isRadio
        self.groups = groups
        self.currentProgramme = currentProgramme
    }
}

public struct ServerLiveTVProgramme: Hashable, Identifiable, Sendable {
    /// Identifies one airing, not just a title which may air on several channels.
    public let id: String
    public let channelID: String
    public let title: String
    public let subtitle: String?
    public let overview: String?
    public let startDate: Date
    public let endDate: Date
    public let imageURL: URL?
    public let categories: [String]

    public init(
        id: String,
        channelID: String,
        title: String,
        subtitle: String? = nil,
        overview: String? = nil,
        startDate: Date,
        endDate: Date,
        imageURL: URL? = nil,
        categories: [String] = []
    ) {
        self.id = id
        self.channelID = channelID
        self.title = title
        self.subtitle = subtitle
        self.overview = overview
        self.startDate = startDate
        self.endDate = endDate
        self.imageURL = imageURL
        self.categories = categories
    }
}

public struct LiveTVPlaybackUpdate: Equatable, Sendable {
    public enum State: String, Sendable {
        case started
        case playing
        case paused
    }

    public let state: State
    public let positionSeconds: TimeInterval

    public init(state: State, positionSeconds: TimeInterval = 0) {
        self.state = state
        self.positionSeconds = positionSeconds.isFinite
            ? max(0, min(positionSeconds, 31_536_000))
            : 0
    }
}

/// Runtime-only ownership of one live playback. Callers close abandoned or
/// replaced leases, including successful opens that arrive after cancellation.
/// Providers also roll back failures before returning a lease. `close` waits for
/// idempotent best-effort cleanup and is safe in an already-cancelled task.
/// Several leases may coexist for one account/device. Closing one must release
/// only its own server-issued handles, never all playback on that device.
public protocol LiveTVStreamLease: Sendable {
    var playbackSource: PlaybackSource { get }
    func report(_ update: LiveTVPlaybackUpdate) async
    func close() async
}

public enum ServerLiveTVError: Error, Equatable, Sendable {
    case permissionDenied
    case subscriptionRequired
    case guideRequired
    case unsupportedAPI
    case unsupportedPlaybackMode
    case tunerUnavailable
    case noCompatibleStream
    case invalidChannel
    case invalidGuideWindow
}
