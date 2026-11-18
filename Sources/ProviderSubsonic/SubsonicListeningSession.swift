import CoreModels
import Foundation

actor SubsonicListeningSession {
    private var previous: PlaybackProgress?
    private var lastTime: TimeInterval = 0
    private var listened: TimeInterval = 0

    func shouldSubmit(
        _ progress: PlaybackProgress, event: PlaybackEvent,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> Bool {
        if event == .start {
            previous = progress
            lastTime = now
            listened = 0
            return false
        }
        guard let previous, previous.itemID == progress.itemID,
              previous.playSessionID == progress.playSessionID else { return false }
        if !previous.isPaused {
            listened += max(0, min(progress.positionSeconds - previous.positionSeconds, now - lastTime))
        }
        self.previous = progress
        lastTime = now
        guard event == .stop else { return false }
        self.previous = nil
        guard let duration = progress.durationSeconds, duration.isFinite, duration > 30 else { return false }
        return listened >= min(duration / 2, 240)
    }
}
