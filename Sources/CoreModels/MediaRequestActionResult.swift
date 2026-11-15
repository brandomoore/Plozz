import Foundation

/// Explicit Seerr request workflow, separate from library coverage. A season can
/// be partially available while its request remains pending or processing.
public enum MediaSeasonRequestStatus: Sendable, Equatable {
    case pending
    case processing
    case failed
    case declined
    case completed
}

/// Seerr's request state for one numbered TV season.
public struct MediaSeasonRequestState: Identifiable, Sendable, Equatable {
    public var id: Int { number }
    public let number: Int
    public let title: String  // l10n:content — season title from the media server
    public var status: MediaAvailabilityStatus
    public var requestFailed: Bool
    public var requestStatus: MediaSeasonRequestStatus?
    public var isPresentInLibrary: Bool
    /// Season premiere calendar day, stored at midnight UTC like MediaItem.releaseDate.
    public var premiereDate: Date?
    public var hasDownloadActivity: Bool

    public init(
        number: Int,
        title: String,  // l10n:content — season title from the media server
        status: MediaAvailabilityStatus,
        requestFailed: Bool = false,
        requestStatus: MediaSeasonRequestStatus? = nil,
        isPresentInLibrary: Bool = false,
        premiereDate: Date? = nil,
        hasDownloadActivity: Bool = false
    ) {
        self.number = number
        self.title = title
        self.status = status
        self.requestFailed = requestFailed
        self.requestStatus = requestStatus
        self.isPresentInLibrary = isPresentInLibrary
        self.premiereDate = premiereDate
        self.hasDownloadActivity = hasDownloadActivity
    }

    /// Request-service state stays authoritative for eligibility. Local episodes
    /// add coverage evidence without turning an untracked season into a managed one.
    public var coverageStatus: MediaAvailabilityStatus {
        isPresentInLibrary && status != .available ? .partiallyAvailable : status
    }

    public var isRequestable: Bool {
        !hasRequestFailure
            && requestStatus == nil
            && (status == .unknown || status == .deleted)
    }

    /// Bulk missing-season actions must not guess that a locally present season
    /// has gaps. Its episode roster can establish that inside the season screen.
    public var isMissingSeasonRequestable: Bool {
        isRequestable && !isPresentInLibrary
    }

    public var isInFlight: Bool {
        guard status != .available, !hasRequestFailure else { return false }
        return switch effectiveRequestStatus {
        case .pending, .processing: true
        case .failed, .declined, .completed, nil: false
        }
    }

    public var statusTitle: LocalizedStringResource {
        statusTitle()
    }

    public func isAwaitingRelease(now: Date = Date(), calendar: Calendar = .current) -> Bool {
        effectiveRequestStatus == .processing
            && coverageStatus != .partiallyAvailable
            && !hasDownloadActivity
            && SeasonEpisodeAvailability.scheduled(
                airDate: premiereDate, now: now, calendar: calendar
            ) == .unaired
    }

    public func statusTitle(now: Date = Date(), calendar: Calendar = .current) -> LocalizedStringResource {
        let coverage = coverageStatus
        if coverage == .available { return "Available" }
        if hasRequestFailure {
            return coverage == .partiallyAvailable
                ? "Partially Available · Request Failed"
                : "Request Failed"
        }
        if requestStatus == .declined {
            return coverage == .partiallyAvailable
                ? "Partially Available · Request Declined"
                : "Request Declined"
        }
        if coverage == .partiallyAvailable {
            switch effectiveRequestStatus {
            case .pending: return "Partially Available · Requested"
            case .processing: return "Partially Available · Processing"
            case .failed, .declined, .completed, nil: return "Partially Available"
            }
        }
        if requestStatus == .completed { return "Request Completed" }
        if effectiveRequestStatus == .pending { return "Requested" }
        if isAwaitingRelease(now: now, calendar: calendar) {
            return "Requested · Unreleased"
        }
        if effectiveRequestStatus == .processing { return "Processing" }
        return switch coverage {
        case .pending: "Requested"
        case .processing: "Processing"
        case .available: "Available"
        case .partiallyAvailable: "Partially Available"
        case .unknown, .deleted: "Request"
        }
    }

    public var statusSystemImage: String {
        if coverageStatus == .available { return "checkmark.circle.fill" }
        if hasRequestFailure || requestStatus == .declined {
            return "exclamationmark.triangle.fill"
        }
        if isAwaitingRelease() { return "calendar" }
        switch effectiveRequestStatus {
        case .pending: return "clock"
        case .processing: return "arrow.triangle.2.circlepath"
        case .completed: return "checkmark.circle"
        case .failed, .declined: return "exclamationmark.triangle.fill"
        case nil: break
        }
        return switch coverageStatus {
        case .pending: "clock"
        case .processing: "arrow.triangle.2.circlepath"
        case .available: "checkmark.circle.fill"
        case .partiallyAvailable: "circle.lefthalf.filled"
        case .unknown, .deleted: "plus.circle"
        }
    }

    /// Only missing or in-flight seasons belong in request UI. Available and
    /// partially available seasons remain represented by the real library tabs.
    public var belongsInRequestPicker: Bool {
        hasRequestFailure || requestStatus == .declined || isMissingSeasonRequestable || isInFlight
    }

    var effectiveRequestStatus: MediaSeasonRequestStatus? {
        if status == .available { return nil }
        if requestFailed || requestStatus == .failed { return .failed }
        if let requestStatus { return requestStatus }
        return switch status {
        case .pending: .pending
        case .processing: .processing
        case .unknown, .partiallyAvailable, .available, .deleted: nil
        }
    }

    var hasRequestFailure: Bool {
        requestFailed || requestStatus == .failed
    }
}

/// Provider-agnostic request coverage for a movie or series.
public struct MediaRequestAvailability: Sendable, Equatable {
    public var status: MediaAvailabilityStatus
    public var downloadProgress: Double?
    public var hasDownloadActivity: Bool
    public var seasons: [MediaSeasonRequestState]

    public init(
        status: MediaAvailabilityStatus,
        downloadProgress: Double? = nil,
        hasDownloadActivity: Bool = false,
        seasons: [MediaSeasonRequestState] = []
    ) {
        self.status = status
        self.downloadProgress = downloadProgress
        self.hasDownloadActivity = hasDownloadActivity
        self.seasons = seasons
    }

    public var requestPickerSeasons: [MediaSeasonRequestState] {
        canonicalNumberedSeasons.filter(\.belongsInRequestPicker)
    }

    public var requestableSeasonNumbers: [Int] {
        canonicalNumberedSeasons.filter(\.isRequestable).map(\.number)
    }

    public var requestableMissingSeasonNumbers: [Int] {
        canonicalNumberedSeasons.filter(\.isMissingSeasonRequestable).map(\.number)
    }

    public var hasSeasonRequestContent: Bool {
        !requestPickerSeasons.isEmpty
    }

    public func markingRequested(_ seasonNumbers: [Int]) -> Self {
        let requested = Set(seasonNumbers.filter { $0 > 0 })
            .intersection(Set(requestableSeasonNumbers))
        guard !requested.isEmpty else { return self }
        var copy = self
        copy.seasons = seasons.map { season in
            guard requested.contains(season.number), season.isRequestable else { return season }
            var updated = season
            updated.status = .pending
            updated.requestFailed = false
            updated.requestStatus = .pending
            return updated
        }
        return copy
    }

    public func markingAvailable(_ seasonNumbers: [Int]) -> Self {
        let available = Set(seasonNumbers.filter { $0 > 0 })
        guard !available.isEmpty else { return self }
        var copy = self
        copy.seasons = seasons.map { season in
            guard available.contains(season.number) else { return season }
            var updated = season
            updated.status = .available
            updated.requestFailed = false
            updated.requestStatus = nil
            return updated
        }
        return copy
    }

    /// Adds conservative local-library evidence without overwriting Seerr's
    /// authoritative request state. Seeing one or more owned episodes proves only
    /// partial season availability, not that the whole season is complete.
    public func markingPresentInLibrary(_ seasonNumbers: [Int]) -> Self {
        let present = Set(seasonNumbers.filter { $0 > 0 })
        var copy = self
        copy.seasons = seasons.map { season in
            var updated = season
            updated.isPresentInLibrary = present.contains(season.number)
            return updated
        }
        return copy
    }

    /// Keeps successful submissions visible across Seerr's eventually consistent
    /// detail reads. Only seasons explicitly accepted by the just-completed request
    /// may borrow state from `previous`; every other season comes solely from this
    /// fetched snapshot.
    public func reconcilingAccepted(
        _ acceptedSeasonNumbers: Set<Int>,
        previous: MediaRequestAvailability?
    ) -> Self {
        let accepted = Set(acceptedSeasonNumbers.filter { $0 > 0 })
        let previousByNumber = Dictionary(
            uniqueKeysWithValues: (previous?.canonicalNumberedSeasons ?? []).map { ($0.number, $0) }
        )
        var reconciled: [Int: MediaSeasonRequestState] = [:]

        for fetched in canonicalNumberedSeasons {
            if accepted.contains(fetched.number),
               fetched.status == .unknown,
               fetched.requestStatus == nil,
               !fetched.hasRequestFailure {
                reconciled[fetched.number] = Self.pendingSeason(
                    number: fetched.number,
                    preferred: previousByNumber[fetched.number] ?? fetched
                )
            } else {
                reconciled[fetched.number] = fetched
            }
        }

        for number in accepted where reconciled[number] == nil {
            reconciled[number] = Self.pendingSeason(
                number: number,
                preferred: previousByNumber[number]
            )
        }

        var copy = self
        copy.seasons = reconciled.values.sorted { $0.number < $1.number }
        return copy
    }

    public var canonicalNumberedSeasons: [MediaSeasonRequestState] {
        var byNumber: [Int: MediaSeasonRequestState] = [:]
        for season in seasons where season.number > 0 {
            guard let existing = byNumber[season.number] else {
                byNumber[season.number] = season
                continue
            }
            byNumber[season.number] = Self.preferred(existing, season)
        }
        return byNumber.values.sorted { $0.number < $1.number }
    }

    private static func pendingSeason(
        number: Int,
        preferred: MediaSeasonRequestState?
    ) -> MediaSeasonRequestState {
        MediaSeasonRequestState(
            number: number,
            title: preferred?.title ?? "Season \(number)",
            status: .pending,
            requestStatus: .pending,
            isPresentInLibrary: preferred?.isPresentInLibrary ?? false,
            premiereDate: preferred?.premiereDate,
            hasDownloadActivity: preferred?.hasDownloadActivity ?? false
        )
    }

    private static func preferred(
        _ lhs: MediaSeasonRequestState,
        _ rhs: MediaSeasonRequestState
    ) -> MediaSeasonRequestState {
        let coverage = precedence(of: lhs) >= precedence(of: rhs) ? lhs.status : rhs.status
        let workflow = preferredRequestStatus(
            lhs.effectiveRequestStatus,
            rhs.effectiveRequestStatus
        )
        let title: String // l10n:content - preferred server-supplied season name
        if lhs.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !rhs.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            title = rhs.title
        } else {
            title = lhs.title
        }
        let effectiveWorkflow = coverage == .available ? nil : workflow
        return MediaSeasonRequestState(
            number: lhs.number,
            title: title,
            status: coverage,
            requestFailed: effectiveWorkflow == .failed,
            requestStatus: effectiveWorkflow,
            isPresentInLibrary: lhs.isPresentInLibrary || rhs.isPresentInLibrary,
            premiereDate: [lhs.premiereDate, rhs.premiereDate].compactMap { $0 }.min(),
            hasDownloadActivity: lhs.hasDownloadActivity || rhs.hasDownloadActivity
        )
    }

    private static func precedence(of season: MediaSeasonRequestState) -> Int {
        if season.status == .available { return 70 }
        if season.status == .partiallyAvailable { return 60 }
        return switch season.status {
        case .processing: 40
        case .pending: 30
        case .deleted: 20
        case .unknown: 10
        case .partiallyAvailable, .available: 0
        }
    }

    private static func preferredRequestStatus(
        _ lhs: MediaSeasonRequestStatus?,
        _ rhs: MediaSeasonRequestStatus?
    ) -> MediaSeasonRequestStatus? {
        func rank(_ status: MediaSeasonRequestStatus?) -> Int {
            switch status {
            case .processing: 60
            case .pending: 50
            case .failed: 40
            case .declined: 30
            case .completed: 20
            case nil: 10
            }
        }
        return rank(lhs) >= rank(rhs) ? lhs : rhs
    }
}

/// The result of a one-tap "Request" action (Seerr/Overseerr), in a
/// provider-agnostic shape so `FeatureHome` can surface success + typed failures
/// without importing the Seerr module. `AppShell` maps the concrete
/// `SeerRequestOutcome` onto this (translating failure reasons into user-facing
/// copy, including the acting user's name where relevant).
public struct MediaRequestActionResult: Sendable, Equatable {
    /// The browsing destination's resulting availability. Absent for failures,
    /// cancellation, and confirmations about another destination.
    public var status: MediaAvailabilityStatus?
    /// A short, user-facing failure title (e.g. "Request Limit Reached"). `nil`
    /// on success. Non-nil signals the UI to present a failure alert.
    public var failureTitle: LocalizedStringResource?
    /// An optional longer explanation shown under `failureTitle`.
    ///
    /// Modelled rather than typed `String` because it is BOTH: most failures
    /// carry our own wording, and one carries whatever Seerr sent back. It was a
    /// String marked as server text, which was true for exactly one of five
    /// cases — the other four rendered our copy verbatim and never reached the
    /// catalog. An enum makes each caller say which it is.
    public enum FailureMessage: Equatable, Sendable {
        /// Plozz's own wording — translatable.
        case copy(LocalizedStringResource)
        /// Text the Seerr server sent us — rendered verbatim, never translated.
        case serverText(String)
    }

    public var failureMessage: FailureMessage?
    public var confirmation: LocalizedStringResource?

    public init(status: MediaAvailabilityStatus? = nil, failureTitle: LocalizedStringResource? = nil, failureMessage: FailureMessage? = nil, confirmation: LocalizedStringResource? = nil) {
        self.status = status
        self.failureTitle = failureTitle
        self.failureMessage = failureMessage
        self.confirmation = confirmation
    }

    /// Whether the request succeeded (a status is present and no failure title).
    public var isSuccess: Bool { status != nil && failureTitle == nil }

    public static func success(_ status: MediaAvailabilityStatus) -> MediaRequestActionResult {
        MediaRequestActionResult(status: status)
    }

    public static func failure(title: LocalizedStringResource,
                               message: FailureMessage? = nil) -> MediaRequestActionResult {
        MediaRequestActionResult(failureTitle: title, failureMessage: message)
    }
}
