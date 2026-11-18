#if canImport(AVFoundation)
import AVFoundation
import XCTest
@testable import MediaDownloads

@MainActor
final class OfflineAudioDownloadTests: XCTestCase {
    func testPackageKeepsAlternateLanguagesAndPreferredDefault() async throws {
        let folder = try directory()
        let video = try await fixture(in: folder, video: true, frequency: 440)
        let audio = try await fixture(in: folder, video: false, frequency: 880)
        let output = folder.appendingPathComponent("media.mp4")
        try await OfflineAudioPackageWriter.write(video: video, audio: [
            .init(url: video, language: "en"),
            .init(url: audio, language: "es", isDefault: true)
        ], to: output)
        let asset = AVURLAsset(url: output)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let selection = try await asset.loadMediaSelectionGroup(for: .audible)
        XCTAssertEqual(videoTracks.count, 1)
        XCTAssertEqual(audioTracks.count, 2)
        XCTAssertEqual(selection?.options.compactMap(\.extendedLanguageTag).sorted(), ["en", "es"])
        XCTAssertEqual(selection?.defaultOption?.extendedLanguageTag, "es")
        try await OfflineAudioRenditionValidator.validate(
            fileURL: output, expectedLanguages: ["eng", "spa"], expectedDuration: 2, maximumHeight: 64)
        for languages: [String?] in [["en"], ["en", "ja"], ["en", "es", "fr"]] {
            do {
                try await OfflineAudioRenditionValidator.validate(
                    fileURL: output, expectedLanguages: languages, expectedDuration: 2)
                XCTFail("Missing, extra, or mismatched languages must not be published.")
            } catch OfflineAudioRenditionValidator.Failure.audioInventory {}
        }
        do {
            try await OfflineAudioRenditionValidator.validate(
                fileURL: output, expectedLanguages: ["en", "es"], expectedDuration: 30)
            XCTFail("A short rendition must not be published.")
        } catch OfflineAudioRenditionValidator.Failure.incomplete {}
        do {
            try await OfflineAudioRenditionValidator.validate(
                fileURL: output, expectedLanguages: ["en", "es"], expectedDuration: 2, maximumHeight: 32)
            XCTFail("An unreduced rendition must not be published.")
        } catch OfflineAudioRenditionValidator.Failure.resolution {}
    }

    func testExtraAudioRetryDoesNotTransferVideoAgain() async throws {
        let folder = try directory()
        let video = try await fixture(in: folder, video: true, frequency: 440)
        let audio = try await fixture(in: folder, video: false, frequency: 880)
        let transfers = Transfers(video: video, audio: audio)
        let plan = plan()
        let output = folder.appendingPathComponent("media.mp4")
        do {
            _ = try await OfflineAudioDownload.download(
                plan: plan, to: output, authorize: {},
                transfer: { id, url, progress in try await transfers.copy(id: id, to: url) },
                finishPreparation: { _ in }, onProgress: { _, _ in }
            )
            XCTFail("The interrupted audio transfer must not publish the video.")
        } catch FixtureError.interrupted {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        let bytes = try await OfflineAudioDownload.download(
            plan: plan, to: output, authorize: {},
            transfer: { id, url, progress in try await transfers.copy(id: id, to: url) },
            finishPreparation: { _ in }, onProgress: { _, _ in }
        )
        let counts = await transfers.counts()
        XCTAssertEqual(counts.video, 1)
        XCTAssertEqual(counts.audio, 2)
        XCTAssertGreaterThan(bytes, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("offline-video.mp4").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("offline-audio-2.m4a").path))
        let restoredBytes = try await OfflineAudioDownload.download(
            plan: plan, to: output, authorize: {},
            transfer: { _, _, _ in throw FixtureError.unexpectedTransfer },
            finishPreparation: { _ in throw FixtureError.unexpectedTransfer }, onProgress: { _, _ in }
        )
        XCTAssertEqual(restoredBytes, bytes)
    }

    func testSourceChangeRejectsRetainedVideo() async throws {
        let folder = try directory()
        let video = try await fixture(in: folder, video: true, frequency: 440)
        let transfers = Transfers(video: video, audio: video)
        let output = folder.appendingPathComponent("media.mp4")
        do {
            _ = try await OfflineAudioDownload.download(
                plan: plan(), to: output, authorize: {},
                transfer: { id, url, _ in try await transfers.copy(id: id, to: url) },
                finishPreparation: { _ in }, onProgress: { _, _ in }
            )
            XCTFail("Expected interrupted transfer.")
        } catch FixtureError.interrupted {}
        do {
            _ = try await OfflineAudioDownload.download(
                plan: plan(fingerprint: "replacement-source"), to: output, authorize: {},
                transfer: { _, _, _ in throw FixtureError.unexpectedTransfer },
                finishPreparation: { _ in }, onProgress: { _, _ in }
            )
            XCTFail("Must not combine two source versions.")
        } catch OfflineAudioDownload.Failure.sourceChanged {}
    }

    func testUnauthorizedWorkNeverTransfers() async throws {
        let folder = try directory()
        do {
            _ = try await OfflineAudioDownload.download(
                plan: plan(), to: folder.appendingPathComponent("media.mp4"),
                authorize: { throw CancellationError() },
                transfer: { _, _, _ in throw FixtureError.unexpectedTransfer },
                finishPreparation: { _ in }, onProgress: { _, _ in }
            )
            XCTFail("Expected cancellation.")
        } catch is CancellationError {}
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }

    func testWriterDoesNotOverwriteExistingOutput() async throws {
        let folder = try directory()
        let output = folder.appendingPathComponent("existing.mp4")
        let bytes = Data("keep existing output".utf8)
        try bytes.write(to: output)
        do {
            try await OfflineAudioPackageWriter.write(
                video: output, audio: [.init(url: output, language: "en")], to: output
            )
            XCTFail("Expected invalid output rejection.")
        } catch OfflineAudioPackageWriter.Failure.invalidSource {}
        XCTAssertEqual(try Data(contentsOf: output), bytes)
    }

    func testDownloadDoesNotReplaceAnUnownedOutput() async throws {
        let folder = try directory()
        let output = folder.appendingPathComponent("media.mp4")
        let bytes = Data("previous download".utf8)
        try bytes.write(to: output)
        do {
            _ = try await OfflineAudioDownload.download(
                plan: plan(), to: output, authorize: {},
                transfer: { _, _, _ in throw FixtureError.unexpectedTransfer },
                finishPreparation: { _ in }, onProgress: { _, _ in })
            XCTFail("An existing file without this job's receipt must not be replaced.")
        } catch OfflineAudioDownload.Failure.invalidReceipt {}
        XCTAssertEqual(try Data(contentsOf: output), bytes)
    }

    func testIncompleteArtifactIsRemovedWithoutACompletionReceipt() async throws {
        let folder = try directory()
        let output = folder.appendingPathComponent("media.mp4")
        let video = try await fixture(in: folder, video: true, frequency: 440)
        let expected = OfflineAudioDownload.Plan(
            sourceFingerprint: "longer-source", tracks: [.init(id: 1, language: "en")],
            primaryAudioID: 1, duration: 30)
        do {
            _ = try await OfflineAudioDownload.download(
                plan: expected, to: output, authorize: {},
                transfer: { _, destination, _ in
                    try FileManager.default.copyItem(at: video, to: destination)
                    return Int64(try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
                },
                finishPreparation: { _ in }, onProgress: { _, _ in })
            XCTFail("A short artifact must not become a completed download.")
        } catch OfflineAudioDownload.Failure.invalidReceipt {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("offline-video.mp4").path))
    }

    private func plan(fingerprint: String = "fixture-v1") -> OfflineAudioDownload.Plan {
        .init(sourceFingerprint: fingerprint, tracks: [
            .init(id: 1, language: "en"), .init(id: 2, language: "es")
        ], primaryAudioID: 1)
    }

    private func directory() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("offline-audio-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: folder) }
        return folder
    }

    private enum FixtureError: Error { case encoding, interrupted, unexpectedTransfer }

    private actor Transfers {
        let video: URL
        let audio: URL
        var videoCount = 0
        var audioCount = 0

        init(video: URL, audio: URL) { self.video = video; self.audio = audio }
        func counts() -> (video: Int, audio: Int) { (videoCount, audioCount) }
        func copy(id: Int?, to destination: URL) throws -> Int64 {
            if id == nil {
                videoCount += 1
            } else {
                audioCount += 1
                if audioCount == 1 { throw FixtureError.interrupted }
            }
            try FileManager.default.copyItem(at: id == nil ? video : audio, to: destination)
            return Int64(try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        }
    }

    private func fixture(in folder: URL, video: Bool, frequency: Double) async throws -> URL {
        let url = folder.appendingPathComponent("\(UUID()).mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        defer { if writer.status == .writing { writer.cancelWriting() } }
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1
        ])
        writer.add(audio)
        let picture = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: picture, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        if video { writer.add(picture) }
        guard writer.startWriting() else { throw writer.error ?? FixtureError.encoding }
        writer.startSession(atSourceTime: .zero)
        if video {
            var buffer: CVPixelBuffer?
            guard CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess,
                  let buffer else { throw FixtureError.encoding }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let address = CVPixelBufferGetBaseAddress(buffer) { memset(address, 0x80, CVPixelBufferGetDataSize(buffer)) }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            for frame in 0..<20 {
                try await ready(picture, writer: writer)
                guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 10)) else {
                    throw writer.error ?? FixtureError.encoding
                }
            }
            picture.markAsFinished()
        }
        var pcm = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2,
            mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0
        )
        var format: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &pcm, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format
        ) == noErr, let format else { throw FixtureError.encoding }
        let samples = (0..<48_000).map { Int16(sin(Double($0) * frequency * 2 * .pi / 48_000) * 8_000) }
        for second in 0..<2 {
            var block: CMBlockBuffer?
            guard CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: 96_000,
                blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                dataLength: 96_000, flags: 0, blockBufferOut: &block
            ) == noErr, let block else { throw FixtureError.encoding }
            let copied = samples.withUnsafeBytes {
                CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block,
                                              offsetIntoDestination: 0, dataLength: $0.count)
            }
            guard copied == noErr else { throw FixtureError.encoding }
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000),
                                           presentationTimeStamp: CMTime(value: Int64(second), timescale: 1),
                                           decodeTimeStamp: .invalid)
            var size = 2
            var sample: CMSampleBuffer?
            guard CMSampleBufferCreateReady(
                allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
                sampleCount: 48_000, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample
            ) == noErr, let sample else { throw FixtureError.encoding }
            try await ready(audio, writer: writer)
            guard audio.append(sample) else { throw writer.error ?? FixtureError.encoding }
        }
        audio.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? FixtureError.encoding }
        return url
    }

    private func ready(_ input: AVAssetWriterInput, writer: AVAssetWriter) async throws {
        for _ in 0..<500 {
            if input.isReadyForMoreMediaData { return }
            guard writer.status == .writing else { throw writer.error ?? FixtureError.encoding }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw FixtureError.encoding
    }
}
#endif
