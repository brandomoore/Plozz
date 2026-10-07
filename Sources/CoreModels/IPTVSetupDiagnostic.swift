import Foundation

/// Explicit setup attempts only. No field can hold an address, credential, name, or error description.
public struct IPTVSetupDiagnostic: Equatable, Sendable {
    public enum Source: String, Sendable { case playlistURL, playlistFile, xtream }
    public enum Authentication: String, Sendable { case url, none, basic, bearer, customHeaders, xtream }
    public enum Entry: String, Sendable { case addAccount, reconnectAccount, addSource, editSource }
    public enum Stage: String, Sendable {
        case validation, catalogOpen, authentication, playlist, channels, movies, series
        case catalogCommit, sessionCreation, persistence
    }
    public enum Outcome: String, Sendable { case started, succeeded, failed, cancelled }
    public enum Response: String, Sendable {
        case playlist, json, html, xml, other

        public init(mimeType: String?) {
            switch mimeType?.lowercased().split(separator: ";").first?.trimmingCharacters(in: .whitespaces) {
            case "application/vnd.apple.mpegurl", "application/x-mpegurl", "audio/mpegurl", "audio/x-mpegurl":
                self = .playlist
            case "application/json": self = .json
            case "text/html", "application/xhtml+xml": self = .html
            case "text/xml", "application/xml": self = .xml
            default: self = .other
            }
        }
    }
    public struct Failure: Equatable, Sendable {
        public enum Reason: String, Codable, Sendable {
            case invalidInput, authentication, expired, unsupported, malformed, empty, storage, tooLarge
            case fileUnavailable, network, timeout, offline, invalidResponse, notFound, rateLimited
            case redirectBlocked, guideInsteadOfPlaylist, accessDenied, sourceChanged, cancelled, other
        }
        public let reason: Reason
        public let networkCode: Int?

        public init(_ reason: Reason, networkCode: Int? = nil) {
            self.reason = reason
            self.networkCode = networkCode.flatMap { (-4_000 ... -1).contains($0) ? $0 : nil }
        }
    }

    public let source: Source
    public let authentication: Authentication
    public let entry: Entry
    public let stage: Stage
    public let outcome: Outcome
    public let failure: Failure?
    public let elapsedMilliseconds: Int
    public let stageMilliseconds: Int
    public let entries: Int?
    public let playlistBytes: Int?
    public let skippedEntries: Int?
    public let requestCount: Int
    public let httpStatus: Int?
    public let response: Response?

    public static func isEnabled(environment: String) -> Bool {
        environment == "debug" || environment == "testflight"
    }
}

/// The reporter installs a sink only while consent and the release channel allow it.
public final class IPTVSetupDiagnostics: @unchecked Sendable {
    public typealias Sink = @Sendable (IPTVSetupDiagnostic) -> Void
    @TaskLocal public static var current: IPTVSetupAttempt?
    public static let shared = IPTVSetupDiagnostics()
    public static let maximumAttempts = 20

    private let lock = NSRecursiveLock()
    private var sink: Sink?
    private var generation = UUID()
    private var remainingAttempts = 0

    public init() {}

    public func start(sink: @escaping Sink) {
        lock.withLock {
            generation = UUID()
            remainingAttempts = Self.maximumAttempts
            self.sink = sink
        }
    }

    public func stop() {
        lock.withLock {
            generation = UUID()
            sink = nil
            remainingAttempts = 0
        }
    }

    public func begin(
        source: IPTVSetupDiagnostic.Source, authentication: IPTVSetupDiagnostic.Authentication,
        entry: IPTVSetupDiagnostic.Entry
    ) -> IPTVSetupAttempt? {
        let generation = lock.withLock { () -> UUID? in
            guard sink != nil, remainingAttempts > 0 else { return nil }
            remainingAttempts -= 1
            return self.generation
        }
        guard let generation else { return nil }
        let attempt = IPTVSetupAttempt(source: source, authentication: authentication, entry: entry) {
            [weak self] diagnostic in
            guard let self else { return }
            self.lock.withLock {
                guard self.generation == generation else { return }
                self.sink?(diagnostic)
            }
        }
        attempt.advance(to: .validation)
        return attempt
    }
}

public final class IPTVSetupAttempt: @unchecked Sendable {
    public static let maximumStageMarkers = 16
    public static let maximumCount = 1_000_000_000_000
    public static let maximumMilliseconds = 86_400_000

    private let lock = NSRecursiveLock()
    private let source: IPTVSetupDiagnostic.Source
    private let authentication: IPTVSetupDiagnostic.Authentication
    private let entry: IPTVSetupDiagnostic.Entry
    private let sink: IPTVSetupDiagnostics.Sink
    private let started = ProcessInfo.processInfo.systemUptime
    private var stageStarted = ProcessInfo.processInfo.systemUptime
    private var stage: IPTVSetupDiagnostic.Stage?
    private var markerCount = 0
    private var finished = false
    private var entries: Int?
    private var playlistBytes: Int?
    private var skippedEntries: Int?
    private var requestCount = 0
    private var httpStatus: Int?
    private var response: IPTVSetupDiagnostic.Response?
    private var transportFailure: IPTVSetupDiagnostic.Failure?

    fileprivate init(
        source: IPTVSetupDiagnostic.Source, authentication: IPTVSetupDiagnostic.Authentication,
        entry: IPTVSetupDiagnostic.Entry, sink: @escaping IPTVSetupDiagnostics.Sink
    ) {
        self.source = source
        self.authentication = authentication
        self.entry = entry
        self.sink = sink
    }

    public func advance(to stage: IPTVSetupDiagnostic.Stage) {
        lock.withLock {
            guard !finished, self.stage != stage else { return }
            self.stage = stage
            stageStarted = ProcessInfo.processInfo.systemUptime
            guard markerCount < Self.maximumStageMarkers else { return }
            markerCount += 1
            sink(snapshot(outcome: .started))
        }
    }

    public func willRequest() {
        lock.withLock {
            guard !finished else { return }
            requestCount = min(Self.maximumCount, requestCount + 1)
            httpStatus = nil
            response = nil
            transportFailure = nil
        }
    }

    public func recordTransportFailure(_ failure: IPTVSetupDiagnostic.Failure) {
        lock.withLock {
            guard !finished, [.network, .timeout, .offline].contains(failure.reason) else { return }
            transportFailure = failure
        }
    }

    public func received(status: Int, response: IPTVSetupDiagnostic.Response) {
        lock.withLock {
            guard !finished else { return }
            httpStatus = (100...599).contains(status) ? status : nil
            self.response = response
        }
    }

    /// Called at parser/library completion, not once per byte or channel.
    public func record(entries: Int? = nil, playlistBytes: Int? = nil, skippedEntries: Int? = nil) {
        lock.withLock {
            guard !finished else { return }
            if let entries {
                self.entries = min(Self.maximumCount, (self.entries ?? 0) + Self.count(entries))
            }
            if let playlistBytes { self.playlistBytes = Self.count(playlistBytes) }
            if let skippedEntries {
                self.skippedEntries = Self.count(skippedEntries)
            }
        }
    }

    public func finish(_ failure: IPTVSetupDiagnostic.Failure? = nil) {
        lock.withLock {
            guard !finished else { return }
            finished = true
            let failure = failure?.reason == .network ? transportFailure ?? failure : failure
            let outcome: IPTVSetupDiagnostic.Outcome = failure?.reason == .cancelled
                ? .cancelled : failure == nil ? .succeeded : .failed
            sink(snapshot(outcome: outcome, failure: outcome == .failed ? failure : nil))
        }
    }

    private static func count(_ value: Int) -> Int { min(max(0, value), maximumCount) }

    private func snapshot(
        outcome: IPTVSetupDiagnostic.Outcome, failure: IPTVSetupDiagnostic.Failure? = nil
    ) -> IPTVSetupDiagnostic {
        let now = ProcessInfo.processInfo.systemUptime
        func milliseconds(since start: TimeInterval) -> Int {
            Int(min(Double(Self.maximumMilliseconds), max(0, (now - start) * 1_000)))
        }
        return IPTVSetupDiagnostic(
            source: source, authentication: authentication, entry: entry, stage: stage ?? .validation,
            outcome: outcome, failure: failure, elapsedMilliseconds: milliseconds(since: started),
            stageMilliseconds: milliseconds(since: stageStarted), entries: entries,
            playlistBytes: playlistBytes, skippedEntries: skippedEntries, requestCount: requestCount,
            httpStatus: httpStatus, response: response
        )
    }
}
