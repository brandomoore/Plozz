#if os(iOS)
import CoreModels
import Foundation
import Observation

/// Keeps Mozz's line animation cadence while Plozz owns lyrics lookup and caching.
@MainActor
@Observable
final class LyricsController {
    typealias State = AudioPlaybackController.LyricsState
    private let playback: MusicPlayerAdapter
    private(set) var activeIndex: Int?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var anchorElapsed: TimeInterval = 0
    @ObservationIgnored private var anchorDate = Date()
    @ObservationIgnored private var lastSample: TimeInterval = -1

    init(playback: MusicPlayerAdapter) { self.playback = playback }
    deinit { ticker?.cancel() }

    var state: State { playback.controller.lyricsState }
    var estimatedElapsed: TimeInterval {
        guard playback.snapshot.status == .playing else { return playback.controller.currentTime }
        return anchorElapsed + min(max(0, Date().timeIntervalSince(anchorDate)), 0.75)
    }

    func load(track: Track?) {
        activeIndex = nil
        resetAnchor()
    }

    func setVisible(_ visible: Bool) {
        ticker?.cancel()
        ticker = nil
        guard visible else { return }
        resetAnchor()
        tick()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled, let self else { return }
                self.tick()
            }
        }
    }

    func seek(toLine index: Int) {
        guard case let .loaded(lyrics) = state,
              lyrics.lines.indices.contains(index),
              let time = lyrics.lines[index].start else { return }
        playback.seek(to: time)
        anchorElapsed = time
        anchorDate = Date()
        lastSample = time
    }

    private func resetAnchor() {
        anchorElapsed = playback.controller.currentTime
        anchorDate = Date()
        lastSample = anchorElapsed
    }

    private func tick() {
        if playback.controller.currentTime != lastSample { resetAnchor() }
        guard case let .loaded(lyrics) = state, lyrics.isSynced else {
            activeIndex = nil
            return
        }
        activeIndex = lyrics.lines.lastIndex { line in
            guard let start = line.start else { return false }
            return start <= estimatedElapsed + 0.3
        }
    }
}

extension AudioPlaybackController.LyricsState {
    var isResolving: Bool {
        switch self {
        case .idle, .loading: true
        case .loaded, .unavailable, .silent: false
        }
    }
}
#endif
