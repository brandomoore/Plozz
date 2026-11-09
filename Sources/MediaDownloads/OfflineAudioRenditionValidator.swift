#if canImport(AVFoundation)
import AVFoundation
import CoreModels
import Foundation

public enum OfflineAudioRenditionValidator {
    public enum Failure: LocalizedError {
        case audioInventory
        case incomplete
        case resolution

        public var errorDescription: String? {
            switch self {
            case .audioInventory:
                String(localized: "The server did not preserve all audio tracks. Choose Original quality or retry.") // l10n:content - LocalizedError requires resolved text; recomputed on each access.
            case .incomplete:
                String(localized: "The server returned an incomplete download. Please retry.") // l10n:content - LocalizedError requires resolved text; recomputed on each access.
            case .resolution:
                String(localized: "The server did not use the requested download resolution.") // l10n:content - LocalizedError requires resolved text; recomputed on each access.
            }
        }
    }

    public static func validate(
        fileURL: URL, expectedLanguages: [String?],
        expectedDuration: TimeInterval?, maximumHeight: Int? = nil
    ) async throws {
        try Task.checkCancellation()
        guard fileURL.isFileURL, expectedLanguages.count <= 64 else { throw Failure.audioInventory }
        let asset = AVURLAsset(url: fileURL)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        let video = try await asset.loadTracks(withMediaType: .video)
        guard audio.count == expectedLanguages.count else { throw Failure.audioInventory }
        guard video.count == 1 else { throw Failure.incomplete }
        if let maximumHeight {
            let size = try await video[0].load(.naturalSize)
            guard maximumHeight > 0, size.height > 0, size.height <= Double(maximumHeight) + 2 else {
                throw Failure.resolution
            }
        }
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw Failure.incomplete }
        let expected = expectedDuration ?? duration
        guard expected.isFinite, expected > 0 else { throw Failure.incomplete }
        let minimumEnd = max(0, expected - max(2, min(10, expected * 0.005)))
        guard duration >= minimumEnd else { throw Failure.incomplete }
        for (track, language) in zip(audio, expectedLanguages) {
            try Task.checkCancellation()
            if let language, !language.isEmpty, language.lowercased() != "und" {
                let extended = try await track.load(.extendedLanguageTag)
                let code = try await track.load(.languageCode)
                guard LanguageMatch.matches(language, extended ?? code) else { throw Failure.audioInventory }
            }
        }
        for track in video + audio {
            try Task.checkCancellation()
            let reader = try AVAssetReader(asset: asset)
            defer { reader.cancelReading() }
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { throw Failure.incomplete }
            reader.add(output)
            let start = max(0, minimumEnd - 1)
            reader.timeRange = CMTimeRange(
                start: CMTime(seconds: start, preferredTimescale: 600),
                duration: CMTime(seconds: max(1, duration - start), preferredTimescale: 600)
            )
            guard reader.startReading() else { throw reader.error ?? Failure.incomplete }
            var latestEnd: Double?
            while let sample = output.copyNextSampleBuffer() {
                try Task.checkCancellation()
                let timestamp = CMSampleBufferGetPresentationTimeStamp(sample)
                let length = CMSampleBufferGetDuration(sample)
                let end = (length.isNumeric ? CMTimeAdd(timestamp, length) : timestamp).seconds
                if end.isFinite { latestEnd = max(latestEnd ?? end, end) }
            }
            guard reader.status == .completed, let latestEnd, latestEnd >= minimumEnd else {
                throw reader.error ?? Failure.incomplete
            }
        }
    }
}
#endif
