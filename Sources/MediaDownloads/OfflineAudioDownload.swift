#if canImport(AVFoundation)
import AVFoundation
import Foundation

/// One video's durable transfer receipts survive failures in its extra soundtracks.
/// The caller owns authorization, provider preparation, and network policy.
public enum OfflineAudioDownload {
    public struct Track: Codable, Hashable, Sendable {
        public let id: Int
        public let language: String?
        public let title: String?

        public init(id: Int, language: String?, title: String? = nil) {
            self.id = id
            self.language = language
            self.title = title
        }
    }

    public struct Plan: Codable, Hashable, Sendable {
        public enum AudioFormat: String, Codable, Hashable, Sendable {
            case m4a
            case aac
        }
        public let sourceFingerprint: String
        public let tracks: [Track]
        public let primaryAudioID: Int
        public let audioFormat: AudioFormat
        public let duration: TimeInterval?

        public init(
            sourceFingerprint: String, tracks: [Track], primaryAudioID: Int,
            audioFormat: AudioFormat = .m4a, duration: TimeInterval? = nil
        ) {
            self.sourceFingerprint = sourceFingerprint
            self.tracks = tracks
            self.primaryAudioID = primaryAudioID
            self.audioFormat = audioFormat
            self.duration = duration
        }
    }

    public enum Failure: Error, Sendable {
        case invalidPlan
        case sourceChanged
        case invalidReceipt
        case insufficientSpace
    }

    public typealias Progress = @Sendable (Int64, Int64) async -> Void
    public typealias Transfer =
        @Sendable (_ audioTrackID: Int?, _ destination: URL, _ progress: @escaping Progress) async throws -> Int64

    private struct Receipt: Codable {
        let plan: Plan
        var files: [String: Int64] = [:]
        var publishedBytes: Int64?
    }

    public static func download(
        plan: Plan,
        to destination: URL,
        authorize: @escaping @Sendable () async throws -> Void,
        transfer: @escaping Transfer,
        finishPreparation: @escaping @Sendable (Int?) async throws -> Void,
        onProgress: @escaping Progress
    ) async throws -> Int64 {
        guard !plan.sourceFingerprint.isEmpty, !plan.tracks.isEmpty, plan.tracks.count <= 64,
              Set(plan.tracks.map(\.id)).count == plan.tracks.count,
              plan.tracks.contains(where: { $0.id == plan.primaryAudioID }),
              destination.isFileURL, destination.lastPathComponent == "media.mp4" else {
            throw Failure.invalidPlan
        }
        try await authorize()
        try Task.checkCancellation()
        let folder = destination.deletingLastPathComponent()
        let receiptURL = folder.appendingPathComponent("audio-package.json")
        let partial = folder.appendingPathComponent("audio-package.partial.mp4")
        var receipt: Receipt
        if FileManager.default.fileExists(atPath: receiptURL.path) {
            receipt = try JSONDecoder().decode(Receipt.self, from: Data(contentsOf: receiptURL))
            guard receipt.plan == plan else { throw Failure.sourceChanged }
        } else {
            guard !FileManager.default.fileExists(atPath: destination.path) else {
                throw Failure.invalidReceipt
            }
            receipt = Receipt(plan: plan)
            try persist(receipt, at: receiptURL)
        }
        if let bytes = receipt.publishedBytes {
            guard try fileSize(destination) == bytes else { throw Failure.invalidReceipt }
            try cleanup(receipt: receipt, folder: folder, partial: partial)
            return bytes
        }
        let stages: [Int?] = [nil] + plan.tracks.filter { $0.id != plan.primaryAudioID }.map { Optional($0.id) }
        for stage in stages {
            try await authorize()
            try Task.checkCancellation()
            let name = fileName(for: stage, format: plan.audioFormat)
            let file = folder.appendingPathComponent(name)
            if let bytes = receipt.files[name] {
                guard try fileSize(file) == bytes else { throw Failure.invalidReceipt }
            } else {
                let alreadyTransferred = receipt.files.values.reduce(0, +)
                let bytes = try await transfer(stage, file) { received, total in
                    // Unknown remaining soundtrack sizes must not look complete.
                    await onProgress(alreadyTransferred + received, 0)
                }
                try await authorize()
                try Task.checkCancellation()
                guard bytes > 0, try fileSize(file) == bytes else { throw Failure.invalidReceipt }
                do {
                    try await validateArtifact(file, audioOnly: stage != nil, duration: plan.duration)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    for owned in [file, file.appendingPathExtension("source"), file.appendingPathExtension("resume")] {
                        if FileManager.default.fileExists(atPath: owned.path) {
                            try FileManager.default.removeItem(at: owned)
                        }
                    }
                    try await finishPreparation(stage)
                    throw error
                }
                receipt.files[name] = bytes
                try persist(receipt, at: receiptURL)
            }
            try await finishPreparation(stage)
            try await authorize()
        }
        try Task.checkCancellation()
        let required = receipt.files.values.reduce(0, +)
        let available = try folder.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity
        if let available, Int64(available) < required { throw Failure.insufficientSpace }
        if FileManager.default.fileExists(atPath: partial.path) {
            try FileManager.default.removeItem(at: partial)
        }
        let primary = folder.appendingPathComponent(fileName(for: nil, format: plan.audioFormat))
        let audio = plan.tracks.map { track in
            OfflineAudioPackageWriter.Audio(
                url: track.id == plan.primaryAudioID
                    ? primary : folder.appendingPathComponent(fileName(for: track.id, format: plan.audioFormat)),
                language: track.language, title: track.title,
                isDefault: track.id == plan.primaryAudioID
            )
        }
        try await OfflineAudioPackageWriter.write(video: primary, audio: audio, to: partial)
        try await OfflineAudioRenditionValidator.validate(
            fileURL: partial, expectedLanguages: plan.tracks.map(\.language), expectedDuration: plan.duration
        )
        try await authorize()
        try Task.checkCancellation()
        let bytes = try fileSize(partial)
        guard bytes > 0 else { throw Failure.invalidReceipt }
        if FileManager.default.fileExists(atPath: destination.path) {
            // A crash after the previous atomic move can leave an unpublished file.
            // Its matching receipt still owns the inputs used to rebuild it.
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: partial)
        } else {
            try FileManager.default.moveItem(at: partial, to: destination)
        }
        receipt.publishedBytes = bytes
        try persist(receipt, at: receiptURL)
        try cleanup(receipt: receipt, folder: folder, partial: partial)
        await onProgress(bytes, bytes)
        return bytes
    }

    private static func fileName(for audioID: Int?, format: Plan.AudioFormat) -> String {
        audioID.map { "offline-audio-\($0).\(format.rawValue)" } ?? "offline-video.mp4"
    }

    private static func fileSize(_ url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize else { throw Failure.invalidReceipt }
        return Int64(size)
    }

    private static func validateArtifact(_ url: URL, audioOnly: Bool, duration expected: TimeInterval?) async throws {
        let asset = AVURLAsset(url: url)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        let video = try await asset.loadTracks(withMediaType: .video)
        guard audio.count == 1, video.count == (audioOnly ? 0 : 1) else { throw Failure.invalidReceipt }
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw Failure.invalidReceipt }
        if let expected {
            guard expected.isFinite, expected > 0, abs(expected - duration) <= 1 else {
                throw Failure.invalidReceipt
            }
        }
        let reader = try AVAssetReader(asset: asset)
        defer { reader.cancelReading() }
        let outputs = (video + audio).map { AVAssetReaderTrackOutput(track: $0, outputSettings: nil) }
        for output in outputs {
            guard reader.canAdd(output) else { throw Failure.invalidReceipt }
            reader.add(output)
        }
        reader.timeRange = CMTimeRange(
            start: CMTime(seconds: max(0, duration - 1), preferredTimescale: 600),
            duration: CMTime(seconds: min(1, duration), preferredTimescale: 600)
        )
        guard reader.startReading() else { throw reader.error ?? Failure.invalidReceipt }
        for output in outputs {
            var count = 0
            while output.copyNextSampleBuffer() != nil {
                try Task.checkCancellation()
                count += 1
            }
            guard count > 0 else { throw Failure.invalidReceipt }
        }
        guard reader.status == .completed else { throw reader.error ?? Failure.invalidReceipt }
    }

    private static func persist(_ receipt: Receipt, at url: URL) throws {
        try JSONEncoder().encode(receipt).write(to: url, options: .atomic)
    }

    private static func cleanup(receipt: Receipt, folder: URL, partial: URL) throws {
        let names = [fileName(for: nil, format: receipt.plan.audioFormat)] + receipt.plan.tracks
            .filter { $0.id != receipt.plan.primaryAudioID }
            .map { fileName(for: $0.id, format: receipt.plan.audioFormat) }
        for url in names.map({ folder.appendingPathComponent($0) }) + [partial] {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
    }
}
#endif
