import Foundation
#if canImport(OSLog)
import OSLog
#endif

/// Event-driven local evidence. Recording never encodes, reads player logs, or
/// waits for disk. Export happens only through explicit diagnostic submission.
public final class PlaybackDiagnosticJournal: @unchecked Sendable {
    public enum Event: String, Codable, Sendable {
        case requested, resolved, loading, loaded, firstFrame, failed, startupTimedOut, ended
        case compatibilityRetry, codecRetry, renditionRestart, stopped, phaseChanged, engineUnavailable
        case releaseStarted, releaseFinished, failureEvidence
    }
    public enum Source: String, Codable, Sendable {
        case unknown, serverFile, serverHLS, localFile, assetPackage, networkFile, separateAudio, libraryChannel
    }
    public enum Phase: String, Codable, Sendable {
        case idle, loading, playing, paused, seeking, rebuffering, stalled, ended, failed
    }
    public enum StopReason: String, Codable, Sendable {
        case requested, failure, replacement, superseded, offlineSelection
    }
    public enum FailureCode: String, Codable, Sendable {
        case invalidQuality, unavailable, unsupported, authentication, permission, noCompatibleStream
        case sourceUnavailable, noStreams, malformedResponse, negotiationFailed, serverHTTP
        case plexDecision, codecUnavailable, serverRefusal, playback, startupTimedOut
    }

    public struct Failure: Codable, Equatable, Sendable {
        public let code: FailureCode
        public private(set) var kind: StreamingPlaybackFailure.Kind?
        public private(set) var domain: StreamingPlaybackFailure.Domain?
        public private(set) var nativeCode: Int?
        public private(set) var httpStatus: Int?
        public private(set) var engineFailure: PlaybackFailureDiagnostic.EngineFailure?
        public private(set) var providerReason: StreamingQualityError.RefusalReason?
        public private(set) var underlyingErrors: [PlaybackFailureEvidence.ErrorCode] = []

        public init(_ error: StreamingQualityError) {
            switch error {
            case .invalidQuality: code = .invalidQuality
            case .unavailable: code = .unavailable
            case .unsupported: code = .unsupported
            case .authenticationRequired: code = .authentication
            case .permissionDenied: code = .permission
            case .noCompatibleStream: code = .noCompatibleStream
            case .sourceUnavailable: code = .sourceUnavailable
            case .noStreams: code = .noStreams
            case .malformedResponse: code = .malformedResponse
            case .negotiationFailed: code = .negotiationFailed
            case .serverHTTP(let status): code = .serverHTTP; httpStatus = status
            case .plexDecision(let value): code = .plexDecision; nativeCode = value
            case .codecUnavailable: code = .codecUnavailable
            case .serverRefusal(_, let reason): code = .serverRefusal; providerReason = reason
            case .startupTimedOut: code = .startupTimedOut
            case .playback(let failure):
                code = .playback
                kind = failure.kind
                domain = failure.domain
                nativeCode = failure.code
                httpStatus = failure.httpStatus
                engineFailure = failure.engineFailure
                providerReason = failure.providerReason
                underlyingErrors = Array(failure.underlyingErrors.filter(\.isValid).prefix(8))
            }
            nativeCode = nativeCode.flatMap { Int32(exactly: $0).map(Int.init) }
            httpStatus = httpStatus.flatMap { (100...599).contains($0) ? $0 : nil }
        }

        var isValid: Bool {
            nativeCode.map { Int32(exactly: $0) != nil } != false
                && httpStatus.map { (100...599).contains($0) } != false
                && underlyingErrors.count <= 8 && underlyingErrors.allSatisfy(\.isValid)
        }
    }

    public struct Facts: Codable, Equatable, Sendable {
        public let provider: ProviderKind?
        public let content: PlaybackFailureDiagnostic.Content
        public let engine: PlaybackEngineKind?
        public let source: Source
        public let transcoding: Bool
        public let sourceContainer: String?
        public let sourceVideo: String?
        public let sourceAudio: String?
        public let negotiatedCodec: String?
        public let hasServerSession: Bool
        public let outputCodec: DirectPlayVideoCodec?
        public let outputRange: SourceDynamicRange?
        public let quality: StreamingQuality?
        public let codecPreference: StreamingCodecPreference?
        public let sourceRange: SourceDynamicRange?
        public let serverDecision: PlaybackServerDecision?

        public init(
            provider: ProviderKind?, engine: PlaybackEngineKind? = nil, request: PlaybackRequest? = nil,
            content: PlaybackFailureDiagnostic.Content = .onDemand, source: Source? = nil,
            outputCodec: DirectPlayVideoCodec? = nil, outputRange: SourceDynamicRange? = nil,
            streamingOptions: StreamingPlaybackOptions? = nil
        ) {
            self.provider = provider
            self.content = content
            self.engine = engine
            if let source { self.source = source }
            else if request?.externalAudioURL != nil { self.source = .separateAudio }
            else if case .some(.networkFile) = request?.playbackSource { self.source = .networkFile }
            else if let url = request?.streamURL, url.isFileURL {
                self.source = url.pathExtension.lowercased() == "movpkg" ? .assetPackage : .localFile
            } else if request?.isManifestStream == true { self.source = .serverHLS }
            else { self.source = request == nil ? .unknown : .serverFile }
            transcoding = request?.isTranscoding == true
            sourceContainer = Self.token(request?.sourceMetadata?.container, accepts: PlozzigenMediaFormats.supports(container:))
            sourceVideo = Self.token(request?.sourceMetadata?.video?.codec, accepts: PlozzigenMediaFormats.supports(videoCodec:))
            sourceAudio = Self.token(request?.sourceMetadata?.audio?.codec, accepts: PlozzigenMediaFormats.supports(audioCodec:))
            negotiatedCodec = request?.negotiatedStreamingVideoCodec?.rawValue
            hasServerSession = request?.streamingSessionID != nil
            self.outputCodec = outputCodec
            self.outputRange = outputRange
            let options = request?.streamingOptions ?? streamingOptions
            quality = options?.quality
            codecPreference = options?.codec
            sourceRange = SourceDynamicRange.providerHint(from: request?.sourceMetadata)
            serverDecision = request?.serverDecision
        }

        private static func token(_ value: String?, accepts: (String) -> Bool) -> String? {
            guard let value, value.utf8.count <= 32, accepts(value) else { return nil }
            return value.lowercased()
        }

        var isValid: Bool {
            sourceContainer.map(PlozzigenMediaFormats.supports(container:)) != false
                && sourceVideo.map(PlozzigenMediaFormats.supports(videoCodec:)) != false
                && sourceAudio.map(PlozzigenMediaFormats.supports(audioCodec:)) != false
                && negotiatedCodec.map { DirectPlayVideoCodec(rawValue: $0) != nil } != false
                && serverDecision?.isValid != false
        }
    }

    struct Entry: Codable, Sendable {
        let timestamp: Date
        let build: String
        let session: UUID
        let attempt: UUID
        let event: Event
        let facts: Facts
        let elapsedMilliseconds: Int?
        let route: PlaybackFailureEvidence.Route?
        let failure: Failure?
        let phase: Phase?
        let liveFailure: PlaybackFailureDiagnostic?
        let stopReason: StopReason?
        let stage: PlaybackDiagnosticReport.Stage?
        let evidence: PlaybackFailureEvidence?
    }
    struct Journal: Codable {
        var schema = 1
        var discarded = 0
        var entries: [Entry] = []
    }
    enum StorageIssue: String, Encodable, Sendable {
        case locationUnavailable, readFailed, invalidJournal, invalidEvidence, oversized, writeFailed, encodeFailed
    }

    public static let shared = PlaybackDiagnosticJournal(
        url: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Plozz/Diagnostics/playback.json")
    )
    static let maximumEntries = 256
    static let maximumBytes = 128 * 1_024
    static let retention: TimeInterval = 48 * 3_600
    private let url: URL?
    private let clock: @Sendable () -> Date
    private let queue = DispatchQueue(label: "com.plozz.playback.diagnosticJournal", qos: .utility)
    private let lock = NSLock()
    private var pending: [Entry] = []
    private var pendingDiscarded = 0
    private var drainScheduled = false
    private var journal = Journal()
    private var pendingWrite: DispatchWorkItem?
    private var storageIssue: StorageIssue?
    private static let build: String = {
        let value = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        return validBuild(value) ? value : "unknown"
    }()
    #if canImport(OSLog)
    private static let logger = Logger(subsystem: "com.plozz.app", category: "playbackDiagnostics")
    #endif

    init(url: URL?, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.url = url
        self.clock = clock
        queue.async { self.restore() }
    }

    public func record(
        _ event: Event, session: UUID, attempt: UUID, facts: Facts,
        elapsed: TimeInterval? = nil, route: PlaybackFailureEvidence.Route? = nil,
        failure: Failure? = nil, phase: Phase? = nil, liveFailure: PlaybackFailureDiagnostic? = nil,
        stopReason: StopReason? = nil, stage: PlaybackDiagnosticReport.Stage? = nil,
        evidence: PlaybackFailureEvidence? = nil
    ) {
        guard facts.isValid, failure?.isValid != false, liveFailure?.isValid != false,
              evidence?.isValid != false else {
            queue.async { self.storageFailed(.invalidEvidence) }
            return
        }
        let milliseconds = elapsed.flatMap { value -> Int? in
            guard value.isFinite, value >= 0 else { return nil }
            return Int(min(value * 1_000, 172_800_000))
        }
        let entry = Entry(
            timestamp: clock(), build: Self.build, session: session, attempt: attempt,
            event: event, facts: facts, elapsedMilliseconds: milliseconds, route: route, failure: failure,
            phase: phase, liveFailure: liveFailure, stopReason: stopReason, stage: stage, evidence: evidence
        )
        lock.withLock {
            if pending.count == Self.maximumEntries {
                pending.removeFirst()
                pendingDiscarded = min(1_000_000_000, pendingDiscarded + 1)
            }
            pending.append(entry)
            guard !drainScheduled else { return }
            drainScheduled = true
            queue.async { self.drain() }
        }
    }

    /// Await off-main export instead of synchronously joining a disk/encoding queue.
    public func report() async -> String {
        await withCheckedContinuation { continuation in
            queue.async {
                self.drain(scheduleWrite: false)
                self.trim()
                do {
                    let data = try self.encode()
                    continuation.resume(returning:
                        "format=plozz-playback-journal-1\nstorage=\(self.storageIssue?.rawValue ?? "ok")\n"
                            + String(decoding: data, as: UTF8.self))
                } catch {
                    self.storageFailed(.encodeFailed)
                    continuation.resume(returning: "format=plozz-playback-journal-1\nstorage=encodeFailed")
                }
            }
        }
    }

    public struct Export: Encodable, Sendable {
        private let schema = 2
        private let storageAvailable: Bool
        private let storageIssue: StorageIssue?
        private let discarded: Int
        private let entries: [ExportEntry]

        fileprivate init(journal: Journal, storage: StorageIssue?, scope: DiagnosticExportScope) {
            storageAvailable = storage == nil
            storageIssue = storage
            discarded = journal.discarded
            entries = journal.entries.map { ExportEntry($0, scope: scope) }
        }
    }

    private struct ExportEntry: Encodable, Sendable {
        let ageMilliseconds: Int?
        let build: String
        let session: String
        let attempt: String
        let event: Event
        let facts: ExportFacts
        let elapsedMilliseconds: Int?
        let route: PlaybackFailureEvidence.Route?
        let failure: Failure?
        let phase: Phase?
        let liveFailure: PlaybackFailureDiagnostic?
        let stopReason: StopReason?
        let stage: PlaybackDiagnosticReport.Stage?
        let evidence: PlaybackFailureEvidence?

        init(_ entry: Entry, scope: DiagnosticExportScope) {
            ageMilliseconds = scope.ageMilliseconds(for: entry.timestamp)
            build = entry.build
            session = scope.alias(for: entry.session.uuidString)
            attempt = scope.alias(for: entry.attempt.uuidString)
            event = entry.event
            facts = ExportFacts(entry.facts)
            elapsedMilliseconds = entry.elapsedMilliseconds
            route = entry.route
            failure = entry.failure
            phase = entry.phase
            liveFailure = entry.liveFailure
            stopReason = entry.stopReason
            stage = entry.stage
            evidence = entry.evidence
        }
    }

    private struct ExportFacts: Encodable, Sendable {
        let provider: ProviderKind?
        let content: PlaybackFailureDiagnostic.Content
        let engine: PlaybackEngineKind?
        let source: Source
        let transcoding: Bool
        let sourceContainer: String?
        let sourceVideo: String?
        let sourceAudio: String?
        let negotiatedCodec: String?
        let hasServerSession: Bool
        let outputCodec: DirectPlayVideoCodec?
        let outputRange: SourceDynamicRange?
        let quality: StreamingQuality?
        let codecPreference: StreamingCodecPreference?
        let sourceRange: SourceDynamicRange?
        let serverDecision: PlaybackServerDecision?

        init(_ facts: Facts) {
            provider = facts.provider
            content = facts.content
            engine = facts.engine
            source = facts.source
            transcoding = facts.transcoding
            sourceContainer = facts.sourceContainer
            sourceVideo = facts.sourceVideo
            sourceAudio = facts.sourceAudio
            negotiatedCodec = facts.negotiatedCodec
            hasServerSession = facts.hasServerSession
            outputCodec = facts.outputCodec
            outputRange = facts.outputRange
            quality = facts.quality
            codecPreference = facts.codecPreference
            sourceRange = facts.sourceRange
            serverDecision = facts.serverDecision
        }
    }

    public func export(scope: DiagnosticExportScope) async -> Export {
        await withCheckedContinuation { continuation in
            queue.async {
                self.drain(scheduleWrite: false)
                self.trim()
                do {
                    _ = try self.encode()
                    continuation.resume(returning: Export(
                        journal: self.journal, storage: self.storageIssue, scope: scope
                    ))
                } catch {
                    self.storageFailed(.encodeFailed)
                    continuation.resume(returning: Export(
                        journal: Journal(discarded: min(1_000_000_000, self.journal.discarded + self.journal.entries.count)),
                        storage: .encodeFailed, scope: scope
                    ))
                }
            }
        }
    }

    func flush() async {
        await withCheckedContinuation { continuation in
            queue.async {
                self.drain(scheduleWrite: false)
                self.pendingWrite?.cancel()
                self.pendingWrite = nil
                self.persist()
                continuation.resume()
            }
        }
    }

    private func drain(scheduleWrite: Bool = true) {
        let (batch, discarded) = lock.withLock {
            let result = (pending, pendingDiscarded)
            pending = []
            pendingDiscarded = 0
            drainScheduled = false
            return result
        }
        journal.entries.append(contentsOf: batch)
        journal.discarded = min(1_000_000_000, journal.discarded + discarded)
        trim()
        guard scheduleWrite, !batch.isEmpty, pendingWrite == nil else { return }
        let write = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingWrite = nil
            self.persist()
        }
        pendingWrite = write
        queue.asyncAfter(deadline: .now() + .milliseconds(250), execute: write)
    }

    private func trim() {
        let now = clock()
        let before = journal.entries.count
        journal.entries.removeAll { $0.timestamp < now.addingTimeInterval(-Self.retention) }
        if journal.entries.count > Self.maximumEntries {
            journal.entries.removeFirst(journal.entries.count - Self.maximumEntries)
        }
        journal.discarded = min(1_000_000_000, journal.discarded + before - journal.entries.count)
    }

    private func restore() {
        guard let url else { storageFailed(.locationUnavailable); return }
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: Self.maximumBytes + 1) ?? Data()
            guard data.count <= Self.maximumBytes else { storageFailed(.oversized); return }
            let value = try JSONDecoder().decode(Journal.self, from: data)
            guard value.schema == 1, (0...1_000_000_000).contains(value.discarded),
                  value.entries.count <= Self.maximumEntries,
                  value.entries.allSatisfy({
                      Self.validBuild($0.build) && $0.facts.isValid && $0.failure?.isValid != false
                          && $0.liveFailure?.isValid != false
                          && $0.evidence?.isValid != false
                          && $0.elapsedMilliseconds.map { (0...172_800_000).contains($0) } != false
                          && $0.timestamp <= clock().addingTimeInterval(300)
                  }) else { storageFailed(.invalidJournal); return }
            journal = value
            trim()
        } catch CocoaError.fileReadNoSuchFile {
            return
        } catch {
            storageFailed(.readFailed)
        }
    }

    private func persist() {
        trim()
        do {
            let data = try encode()
            guard let url else { storageFailed(.locationUnavailable); return }
            var directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try directory.setResourceValues(values)
            try data.write(to: url, options: .atomic)
        } catch {
            storageFailed(.writeFailed)
        }
    }

    private func encode() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(journal)
        while data.count > Self.maximumBytes, !journal.entries.isEmpty {
            let count = max(1, journal.entries.count / 4)
            journal.entries.removeFirst(count)
            journal.discarded = min(1_000_000_000, journal.discarded + count)
            data = try encoder.encode(journal)
        }
        return data
    }

    private static func validBuild(_ value: String) -> Bool {
        value == "unknown" || (!value.isEmpty && value.utf8.count <= 32
            && value.utf8.allSatisfy { (48...57).contains($0) || $0 == 46 })
    }

    private func storageFailed(_ issue: StorageIssue) {
        guard storageIssue != issue else { return }
        storageIssue = issue
        #if canImport(OSLog)
        Self.logger.error("Playback diagnostic journal unavailable reason=\(issue.rawValue, privacy: .public)")
        #endif
    }
}
