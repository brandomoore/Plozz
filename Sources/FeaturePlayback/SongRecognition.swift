import AVFAudio
import CoreModels
import Foundation
import ShazamKit

/// Song identification in the player's Info card (#351).
/// Listens to the audio Plozz is already playing (the engine's decoded-audio
/// tap, not the microphone) and matches it against Apple's Shazam catalog.

/// One chunk of decoded playback audio: mono Float32 48 kHz PCM, stamped on
/// the source timeline.
public struct SongTapChunk: @unchecked Sendable {
    public let buffer: AVAudioPCMBuffer
    public let sourceTime: Double
    public init(buffer: AVAudioPCMBuffer, sourceTime: Double) {
        self.buffer = buffer
        self.sourceTime = sourceTime
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

enum SongRecognizer {
    /// A song stays on the card this long after Shazam last heard it.
    static let linger: TimeInterval = 25

    /// Listens to everything the tap delivers until the stream ends (reload,
    /// stop) or the task is cancelled, reporting each song as it is heard and
    /// `nil` once nothing has matched for `linger` seconds. A seek restarts the
    /// watch from the player, so one watch only ever hears continuous audio.
    static func watch(
        _ stream: AsyncStream<SongTapChunk>,
        report: @escaping @MainActor @Sendable (SongMatch?) -> Void
    ) async {
        let session = SHSession()
        let signals = WatchSignals()
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                var current: SongMatch?
                var lastHeard = Date.distantPast
                var confirmation = SongConfirmation()
                var lastError: String?
                for await result in session.results {
                    if Task.isCancelled { return }
                    switch result {
                    case let .match(match):
                        let first = match.mediaItems.first
                        guard let item = first, let title = item.title,
                              isSong(title: title, genres: item.genres) else { continue }
                        let song = SongMatch(
                            title: title, artist: item.artist,
                            artworkURL: item.artworkURL, appleMusicURL: item.appleMusicURL
                        )
                        let now = Date(), offset = item.predictedCurrentMatchOffset
                        let key = "\(title)|\(item.artist ?? "")"
                        if song == current {
                            lastHeard = now
                            continue
                        }
                        guard confirmation.confirms(key: key, offset: offset, at: now) else { continue }
                        lastHeard = now
                        lastError = nil
                        current = song
                        HandoffDiagnostics.emit("songid SHOW")
                        await report(song)
                    case let .error(error, _):
                        // Offline, Shazam unreachable, or the app not allowed to
                        // use ShazamKit. Nothing to show the viewer: the card
                        // simply has no song. Rest the matcher for a while
                        // instead of sending every few seconds of audio.
                        let code = "\((error as NSError).domain)#\((error as NSError).code)"
                        if code != lastError {
                            lastError = code
                            HandoffDiagnostics.emit("songid ERROR \(code)")
                        }
                        signals.rest(for: errorRest)
                        fallthrough
                    case .noMatch:
                        if current != nil, Date().timeIntervalSince(lastHeard) > linger {
                            current = nil
                            await report(nil)
                        }
                    }
                }
            }
            group.addTask {
                for await chunk in stream {
                    if Task.isCancelled { break }
                    if signals.isResting { continue }
                    session.matchStreamingBuffer(chunk.buffer, at: nil)
                }
            }
            // The audio ending (reload, stop) ends the watch.
            await group.next()
            group.cancelAll()
        }
    }

    /// How long the matcher rests after an error (offline, service refused).
    static let errorRest: TimeInterval = 30

    /// Lets the results loop pause the audio loop after an error.
    private final class WatchSignals: @unchecked Sendable {
        private let lock = NSLock()
        private var restUntil = Date.distantPast
        var isResting: Bool { lock.withLock { Date() < restUntil } }
        func rest(for seconds: TimeInterval) { lock.withLock { restUntil = Date().addingTimeInterval(seconds) } }
    }

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

    private var sightings: [String: (offset: TimeInterval, at: Date)] = [:]

    mutating func confirms(key: String, offset: TimeInterval, at now: Date) -> Bool {
        let seen = sightings[key]
        sightings[key] = (offset, now)
        sightings = sightings.filter { now.timeIntervalSince($0.value.at) < Self.window }
        guard let seen, now.timeIntervalSince(seen.at) < Self.window,
              abs((offset - seen.offset) - now.timeIntervalSince(seen.at)) < Self.tolerance else { return false }
        sightings = [:]
        return true
    }

}
