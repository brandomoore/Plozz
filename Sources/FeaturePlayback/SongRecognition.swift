import AVFAudio
import CoreModels
import Foundation
import Observation
import ShazamKit

/// Song identification in the player's Info card (#351).
/// Listens to the audio Plozz is already playing (the engine's decoded-audio
/// tap, not the microphone) and matches it against Apple's Shazam catalog.

/// One chunk of decoded playback audio: mono Float32 48 kHz PCM, stamped on
/// the source timeline.
public struct SongTapChunk: @unchecked Sendable {
    public let buffer: AVAudioPCMBuffer
    public let sourceTime: Double
    public let discontinuity: Bool
    public init(buffer: AVAudioPCMBuffer, sourceTime: Double, discontinuity: Bool = false) {
        self.buffer = buffer
        self.sourceTime = sourceTime
        self.discontinuity = discontinuity
    }
}

public struct SongMatch: Equatable, Sendable {
    public let title: String
    public let artist: String?
    public let artworkURL: URL?
    public let appleMusicURL: URL?
}

public enum SongIDState: Equatable, Sendable {
    case idle
    case found(SongMatch)
}

@MainActor @Observable
public final class SongRecognitionModel {
    public var state: SongIDState = .idle
    public var isAvailable = false

    @ObservationIgnored private let now: @MainActor () -> TimeInterval
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private var expiry: Task<Void, Never>?
    @ObservationIgnored private var remaining: TimeInterval = 0
    @ObservationIgnored private var startedAt: TimeInterval?
    @ObservationIgnored private var generation = 0

    init(
        now: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.now = now
        self.sleep = sleep
    }

    deinit { expiry?.cancel() }

    func heard(_ song: SongMatch?) {
        pauseExpiry()
        let next = song.map(SongIDState.found) ?? .idle
        if state != next { state = next }
        remaining = song == nil ? 0 : SongRecognizer.linger
        resumeExpiry()
    }

    func pauseExpiry() {
        if let startedAt { remaining = max(0, remaining - (now() - startedAt)) }
        startedAt = nil
        generation += 1
        expiry?.cancel()
        expiry = nil
    }

    func resumeExpiry() {
        guard expiry == nil, case .found = state else { return }
        guard remaining > 0 else { state = .idle; return }
        startedAt = now()
        let generation = generation, delay = remaining, sleep = sleep
        expiry = Task { [weak self] in
            do { try await sleep(.seconds(delay)) }
            catch is CancellationError { return }
            catch {
                HandoffDiagnostics.emit("songid EXPIRY_WAIT_FAILED")
            }
            guard !Task.isCancelled, self?.generation == generation else { return }
            self?.state = .idle
            self?.remaining = 0
            self?.startedAt = nil
            self?.expiry = nil
        }
    }
}

/// Pulls continuous audio within 50 ms of the rendered source clock.
/// The upstream queue stays bounded; cancellation never stalls the player.
struct SongAudioPacer {
    private(set) var playhead = -Double.infinity

    mutating func wait(
        until end: TimeInterval,
        playbackTime: @MainActor @Sendable () -> TimeInterval
    ) async throws -> Bool {
        guard end.isFinite else { return false }
        while end > playhead + 0.05 {
            try Task.checkCancellation()
            playhead = await playbackTime()
            guard playhead.isFinite else { return false }
            if end > playhead + 0.05 { try await Task.sleep(for: .milliseconds(100)) }
        }
        try Task.checkCancellation()
        return true
    }
}

enum SongRecognizer {
    enum StopReason: Equatable, Sendable {
        case ended, failed, discontinuity
    }

    /// A song stays on the card this long after Shazam last heard it.
    static let linger: TimeInterval = 25

    /// Listens to everything the tap delivers until the stream ends (reload,
    /// stop) or the task is cancelled, reporting confirmed and renewed matches.
    /// Presentation owns expiry across matcher restarts.
    /// A seek restarts the watch, so one watch only hears continuous audio.
    static func watch(
        _ stream: AsyncStream<SongTapChunk>,
        makeSession: @Sendable () -> SHSession = { SHSession() },
        playbackTime: (@MainActor @Sendable () -> TimeInterval)? = nil,
        didFeed: (@Sendable (SongTapChunk, TimeInterval?) -> Void)? = nil,
        didMatch: (@Sendable () -> Void)? = nil,
        report: @escaping @MainActor @Sendable (SongMatch?) -> Void
    ) async -> StopReason {
        let session = makeSession()
        let reason = await withTaskGroup(of: StopReason.self) { group in
            group.addTask {
                var current: SongMatch?
                var lastHeard = -TimeInterval.infinity
                var confirmation = SongConfirmation()
                for await result in session.results {
                    if Task.isCancelled { return .ended }
                    switch result {
                    case let .match(match):
                        didMatch?()
                        let first = match.mediaItems.first
                        guard let item = first, let title = item.title,
                              isSong(title: title, genres: item.genres) else { continue }
                        let song = SongMatch(
                            title: title, artist: item.artist,
                            artworkURL: item.artworkURL, appleMusicURL: item.appleMusicURL
                        )
                        let now = ProcessInfo.processInfo.systemUptime
                        let offset = item.predictedCurrentMatchOffset
                        let key = "\(title)|\(item.artist ?? "")"
                        if now - lastHeard > linger { current = nil }
                        if song == current {
                            lastHeard = now
                            await report(song)
                            continue
                        }
                        let sourceTime = await playbackTime?() ?? now
                        guard confirmation.confirms(key: key, offset: offset, at: sourceTime) else { continue }
                        lastHeard = now
                        current = song
                        HandoffDiagnostics.emit("songid SHOW")
                        await report(song)
                    case let .error(error, _):
                        let code = "\((error as NSError).domain)#\((error as NSError).code)"
                        HandoffDiagnostics.emit("songid ERROR \(code)")
                        await report(nil)
                        return .failed
                    case .noMatch:
                        if current != nil, ProcessInfo.processInfo.systemUptime - lastHeard > linger {
                            current = nil
                        }
                    }
                }
                return .ended
            }
            group.addTask {
                var expectedTime: Double?
                var pacer = SongAudioPacer()
                for await chunk in stream {
                    if Task.isCancelled { break }
                    guard chunk.sourceTime.isFinite, chunk.buffer.format.sampleRate > 0 else {
                        HandoffDiagnostics.emit("songid INVALID_AUDIO")
                        return .failed
                    }
                    if let expectedTime,
                       chunk.discontinuity || abs(chunk.sourceTime - expectedTime) > 0.25 {
                        HandoffDiagnostics.emit("songid DISCONTINUITY")
                        return .discontinuity
                    }
                    expectedTime = chunk.sourceTime
                        + Double(chunk.buffer.frameLength) / chunk.buffer.format.sampleRate
                    if let playbackTime, let end = expectedTime {
                        do {
                            guard try await pacer.wait(until: end, playbackTime: playbackTime) else {
                                HandoffDiagnostics.emit("songid INVALID_PLAYHEAD")
                                return .failed
                            }
                        } catch is CancellationError { return .ended }
                        catch {
                            HandoffDiagnostics.emit("songid PACING_FAILED")
                            return .failed
                        }
                    }
                    session.matchStreamingBuffer(chunk.buffer, at: nil)
                    didFeed?(chunk, playbackTime == nil ? nil : pacer.playhead)
                }
                return .ended
            }
            let reason = await group.next() ?? .ended
            group.cancelAll()
            return reason
        }
        return reason
    }

    /// How long the matcher rests after an error (offline, service refused).
    static let errorRest: TimeInterval = 30

    /// Shazam also knows sound-effect and ambience albums, which match rain and
    /// room tone in quiet scenes, and untagged uploads (no genre) that sample a
    /// film's score. Neither is a song worth showing.
    static func isSong(title: String, genres: [String]) -> Bool {
        guard !genres.isEmpty else { return false }
        if genres.contains(where: { $0.localizedCaseInsensitiveContains("sound effect") }) { return false }
        let title = title.lowercased()
        return !["sounds of ", "sound effect", "ambience", "white noise", "rain sounds"]
            .contains { title.contains($0) }
    }
}

/// A first hearing waits for a second one that agrees: the same song, with its
/// position moved on by the time that passed. Score cues and remixes of a
/// film's theme match once or jump around; a song playing in the scene keeps
/// tracking. Other matches can land in between, so each song keeps its own
/// last sighting.
struct SongConfirmation {
    /// Sightings older than this are forgotten.
    static let window: TimeInterval = 45
    /// How far the song's position may drift from the clock between sightings.
    static let tolerance: TimeInterval = 4

    private var sightings: [String: (offset: TimeInterval, at: TimeInterval)] = [:]

    mutating func confirms(key: String, offset: TimeInterval, at now: TimeInterval) -> Bool {
        let seen = sightings[key]
        sightings[key] = (offset, now)
        sightings = sightings.filter { now - $0.value.at < Self.window }
        guard let seen, now - seen.at < Self.window,
              abs((offset - seen.offset) - (now - seen.at)) < Self.tolerance else { return false }
        sightings = [:]
        return true
    }

}
