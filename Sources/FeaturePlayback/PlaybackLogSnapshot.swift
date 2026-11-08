#if canImport(AVFoundation)
import AVFoundation
import CoreModels
import Foundation

struct PlaybackLogSnapshot: Sendable {
    var indicatedBitrate: Double?
    var observedBitrate: Double?
    var transferredBytes: Int64?
    var droppedFrames: Int?
    var stalls: Int?
    var liveEvents: [PlaybackDiagnostics.LiveStreamFacts.AccessEvent] = []
    var errorCount: Int?
    var lastErrorStatus: Int?
    var programDate: Date?

    nonisolated static func read(_ item: AVPlayerItem) -> Self {
        let events = item.accessLog()?.events ?? []
        let errors = item.errorLog()?.events ?? []
        let last = events.last
        return Self(
            indicatedBitrate: last.map(\.indicatedBitrate),
            observedBitrate: last.map(\.observedBitrate),
            transferredBytes: total(events.map(\.numberOfBytesTransferred)),
            droppedFrames: total(events.map(\.numberOfDroppedVideoFrames)),
            stalls: total(events.map(\.numberOfStalls)),
            liveEvents: events.map {
                .init(
                    playbackType: $0.playbackType, indicatedBitrate: $0.indicatedBitrate, startupTime: $0.startupTime,
                    mediaRequests: $0.numberOfMediaRequests, bytesTransferred: $0.numberOfBytesTransferred,
                    downloadOverdue: $0.downloadOverdue
                )
            },
            errorCount: errors.isEmpty ? nil : errors.count,
            lastErrorStatus: errors.last?.errorStatusCode,
            programDate: item.currentDate()
        )
    }

    nonisolated static func total<T: FixedWidthInteger>(_ values: [T]) -> T? {
        guard !values.isEmpty, values.allSatisfy({ $0 >= 0 }) else { return nil }
        var result: T = 0
        for value in values {
            let sum = result.addingReportingOverflow(value)
            guard !sum.overflow else { return nil }
            result = sum.partialValue
        }
        return result
    }

    func apply(to live: inout PlaybackDiagnostics.LiveStreamFacts) {
        live.apply(accessLog: liveEvents)
        live.errorCount = errorCount
        live.lastErrorStatus = lastErrorStatus
        live.programDate = programDate
    }
}
#endif
