#if canImport(AVFoundation)
@preconcurrency import AVFoundation
import Foundation

/// Combines already-converted files without encoding their video or audio again.
public enum OfflineAudioPackageWriter {
    public struct Audio: Sendable {
        public let url: URL
        public let language: String?
        public let title: String?
        public let isDefault: Bool

        public init(url: URL, language: String?, title: String? = nil, isDefault: Bool = false) {
            self.url = url
            self.language = language
            self.title = title
            self.isDefault = isDefault
        }
    }

    public enum Failure: Error, Sendable {
        case invalidSource
        case unsupportedTrack
        case incompleteTrack
        case writingFailed
    }

    public static func write(video: URL, audio: [Audio], to output: URL) async throws {
        guard video.isFileURL, output.isFileURL, !audio.isEmpty, audio.count <= 64,
              audio.allSatisfy({ $0.url.isFileURL }),
              output != video, !audio.contains(where: { $0.url == output }),
              !FileManager.default.fileExists(atPath: output.path) else {
            throw Failure.invalidSource
        }
        let cancellation = Cancellation()
        try await withTaskCancellationHandler {
            let videoAsset = AVURLAsset(url: video)
            let duration = try await videoAsset.load(.duration)
            guard duration.isNumeric, duration.seconds.isFinite, duration.seconds > 0 else {
                throw Failure.invalidSource
            }
            var inputs: [Input] = []
            let videoTracks = try await videoAsset.loadTracks(withMediaType: .video)
            guard videoTracks.count == 1 else { throw Failure.invalidSource }
            inputs.append(try await Input(asset: videoAsset, track: videoTracks[0], audio: nil))
            for kind: AVMediaType in [.text, .subtitle, .closedCaption] {
                for track in try await videoAsset.loadTracks(withMediaType: kind) {
                    inputs.append(try await Input(asset: videoAsset, track: track, audio: nil))
                }
            }
            for selection in audio {
                try Task.checkCancellation()
                let asset = AVURLAsset(url: selection.url)
                let tracks = try await asset.loadTracks(withMediaType: .audio)
                guard tracks.count == 1 else { throw Failure.invalidSource }
                let range = try await tracks[0].load(.timeRange)
                guard range.start.isNumeric, range.duration.isNumeric,
                      range.start.seconds >= -0.5,
                      range.start.seconds <= 0.5,
                      abs(range.end.seconds - duration.seconds) <= 1 else {
                    throw Failure.incompleteTrack
                }
                inputs.append(try await Input(asset: asset, track: tracks[0], audio: selection))
            }
            try Task.checkCancellation()
            let work = Work(inputs: inputs, output: output, cancellation: cancellation)
            do {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    DispatchQueue(label: "com.thatcube.Plozz.offline-audio-package", qos: .utility).async {
                        do {
                            try work.run()
                            continuation.resume()
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    }
                }
                try Task.checkCancellation()
            } catch {
                if work.ownsOutput, FileManager.default.fileExists(atPath: output.path) {
                    try FileManager.default.removeItem(at: output)
                }
                throw error
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false

        func cancel() { lock.withLock { cancelled = true } }
        func check() throws {
            if lock.withLock({ cancelled }) { throw CancellationError() }
        }
    }

    private struct Input {
        let asset: AVURLAsset
        let track: AVAssetTrack
        let format: CMFormatDescription
        let transform: CGAffineTransform
        let mediaType: AVMediaType
        let language: String?
        let title: String?
        let isDefault: Bool

        init(asset: AVURLAsset, track: AVAssetTrack, audio: Audio?) async throws {
            self.asset = asset
            self.track = track
            guard let format = try await track.load(.formatDescriptions).first else {
                throw Failure.invalidSource
            }
            self.format = format
            self.transform = try await track.load(.preferredTransform)
            self.mediaType = track.mediaType
            if let language = audio?.language {
                self.language = language
            } else {
                self.language = try await track.load(.extendedLanguageTag)
            }
            self.title = audio?.title
            self.isDefault = audio?.isDefault == true
        }
    }

    /// Native readers and the writer stay on one owned worker; cancellation only
    /// changes the lock-protected flag. No encoding runs on the main actor.
    private final class Work: @unchecked Sendable {
        let inputs: [Input]
        let output: URL
        let cancellation: Cancellation
        private(set) var ownsOutput = false

        init(inputs: [Input], output: URL, cancellation: Cancellation) {
            self.inputs = inputs
            self.output = output
            self.cancellation = cancellation
        }

        func run() throws {
            try cancellation.check()
            let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
            ownsOutput = true
            writer.shouldOptimizeForNetworkUse = true
            var readers: [AVAssetReader] = []
            var outputs: [AVAssetReaderTrackOutput] = []
            var writerInputs: [AVAssetWriterInput] = []
            var audioInputs: [AVAssetWriterInput] = []
            var defaultAudio: AVAssetWriterInput?
            var succeeded = false
            defer {
                if !succeeded {
                    for reader in readers { reader.cancelReading() }
                    writer.cancelWriting()
                }
            }
            for spec in inputs {
                let reader = try AVAssetReader(asset: spec.asset)
                let readerOutput = AVAssetReaderTrackOutput(track: spec.track, outputSettings: nil)
                readerOutput.alwaysCopiesSampleData = false
                guard reader.canAdd(readerOutput) else { throw Failure.unsupportedTrack }
                reader.add(readerOutput)
                let input = AVAssetWriterInput(
                    mediaType: spec.mediaType, outputSettings: nil, sourceFormatHint: spec.format
                )
                input.expectsMediaDataInRealTime = false
                if spec.mediaType == .video { input.transform = spec.transform }
                if let language = spec.language, !language.isEmpty { input.extendedLanguageTag = language }
                if let title = spec.title, !title.isEmpty {
                    let metadata = AVMutableMetadataItem()
                    metadata.identifier = .commonIdentifierTitle
                    metadata.value = title as NSString
                    input.metadata = [metadata]
                }
                guard writer.canAdd(input) else { throw Failure.unsupportedTrack }
                writer.add(input)
                if spec.mediaType == .audio {
                    audioInputs.append(input)
                    if spec.isDefault && defaultAudio == nil { defaultAudio = input }
                }
                readers.append(reader)
                outputs.append(readerOutput)
                writerInputs.append(input)
            }
            let group = AVAssetWriterInputGroup(inputs: audioInputs, defaultInput: defaultAudio ?? audioInputs.first)
            guard writer.canAdd(group) else { throw Failure.unsupportedTrack }
            writer.add(group)
            guard writer.startWriting() else { throw writer.error ?? Failure.writingFailed }
            writer.startSession(atSourceTime: .zero)
            for reader in readers {
                guard reader.startReading() else { throw reader.error ?? Failure.invalidSource }
            }
            var unfinished = Set(writerInputs.indices)
            var sampleCounts = Array(repeating: 0, count: writerInputs.count)
            while !unfinished.isEmpty {
                try cancellation.check()
                guard writer.status == .writing else { throw writer.error ?? Failure.writingFailed }
                var advanced = false
                for index in unfinished.sorted() where writerInputs[index].isReadyForMoreMediaData {
                    if let sample = outputs[index].copyNextSampleBuffer() {
                        guard writerInputs[index].append(sample) else {
                            throw writer.error ?? Failure.writingFailed
                        }
                        sampleCounts[index] += 1
                    } else {
                        guard readers[index].status == .completed else {
                            throw readers[index].error ?? Failure.incompleteTrack
                        }
                        if inputs[index].mediaType == .audio || inputs[index].mediaType == .video {
                            guard sampleCounts[index] > 0 else { throw Failure.incompleteTrack }
                        }
                        writerInputs[index].markAsFinished()
                        unfinished.remove(index)
                    }
                    advanced = true
                }
                if !advanced { Thread.sleep(forTimeInterval: 0.01) }
            }
            let finished = DispatchSemaphore(value: 0)
            writer.finishWriting { finished.signal() }
            while finished.wait(timeout: .now() + .milliseconds(50)) == .timedOut {
                try cancellation.check()
            }
            try cancellation.check()
            guard writer.status == .completed else { throw writer.error ?? Failure.writingFailed }
            succeeded = true
        }
    }
}
#endif
