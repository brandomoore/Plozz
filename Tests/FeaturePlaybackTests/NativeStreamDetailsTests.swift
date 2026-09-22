#if canImport(AVFoundation)
import AVFoundation
import CoreModels
import XCTest
@testable import FeaturePlayback

@MainActor
final class NativeStreamDetailsTests: XCTestCase {
    func testUnknownColorIsNotInventedSDROrOriginalHDR() throws {
        let unknown = NativeStreamDetailsReader.videoStream(try videoFormat(transfer: nil))
        XCTAssertEqual(unknown.width, 426)
        XCTAssertEqual(unknown.height, 230)
        XCTAssertEqual(unknown.codec, "h264")
        XCTAssertNil(unknown.videoRangeType)
        let details = PlaybackStreamDetails(metadata: .init(video: unknown))
        XCTAssertEqual(details.diagnostics.hdr, .unknown)
        XCTAssertEqual(details.technicalBadges.map(\.label), ["426×230", "H.264"])
    }

    func testPQIsHDR10NotHDR10PlusAnd709IsSDR() throws {
        let pq = NativeStreamDetailsReader.videoStream(try videoFormat(transfer: kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ))
        XCTAssertEqual(pq.videoRangeType, "HDR10")
        XCTAssertFalse(PlaybackStreamDetails(metadata: .init(video: pq)).technicalBadges.contains { $0.label == "HDR10+" })
        let sdr = NativeStreamDetailsReader.videoStream(try videoFormat(transfer: kCMFormatDescriptionTransferFunction_ITU_R_709_2))
        XCTAssertEqual(sdr.videoRangeType, "SDR")
    }

    func testActualAACStereoFormatDoesNotAcquireSourceSurroundOrAtmos() throws {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 0,
            mBytesPerPacket: 0, mFramesPerPacket: 1024, mBytesPerFrame: 0,
            mChannelsPerFrame: 2, mBitsPerChannel: 0, mReserved: 0
        )
        var description: CMAudioFormatDescription?
        XCTAssertEqual(CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &description
        ), noErr)
        let audio = NativeStreamDetailsReader.audioStream(try XCTUnwrap(description))
        XCTAssertEqual(audio.codec, "aac")
        XCTAssertEqual(audio.channels, 2)
        XCTAssertEqual(audio.sampleRate, 48_000)
        XCTAssertNil(audio.profile)
        XCTAssertEqual(PlaybackStreamDetails(metadata: .init(audio: audio)).technicalBadges.map(\.label), ["AAC Stereo"])
    }

    func testReaderExtractsEncodedResolutionAndAudioFromRealPlayerItem() async throws {
        let url = try await makeVideoWithAudio()
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        defer {
            player.pause()
            player.replaceCurrentItem(with: nil)
            try? FileManager.default.removeItem(at: url)
        }
        for _ in 0..<150 where item.status == .unknown {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(item.status, .readyToPlay)
        let actual = await NativeStreamDetailsReader.read(item)
        XCTAssertEqual(actual.video?.width, 426)
        XCTAssertEqual(actual.video?.height, 230)
        XCTAssertEqual(actual.video?.codec, "h264")
        XCTAssertEqual(actual.audio?.codec, "aac")
        XCTAssertEqual(actual.audio?.channels, 2)
        XCTAssertEqual(actual.audio?.sampleRate, 48_000)
        XCTAssertNil(actual.audio?.profile)
    }

    private func videoFormat(transfer: CFString?) throws -> CMFormatDescription {
        var description: CMVideoFormatDescription?
        let extensions: [CFString: Any] = transfer.map { [kCMFormatDescriptionExtension_TransferFunction: $0] } ?? [:]
        XCTAssertEqual(CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, codecType: kCMVideoCodecType_H264,
            width: 426, height: 230, extensions: extensions as CFDictionary,
            formatDescriptionOut: &description
        ), noErr)
        return try XCTUnwrap(description)
    }

    private func makeVideoWithAudio() async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("stream-facts-\(UUID()).mp4")
        addTeardownBlock {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        defer { if writer.status == .writing { writer.cancelWriting() } }
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 426, AVVideoHeightKey: 230
        ])
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 426, kCVPixelBufferHeightKey as String: 230
        ])
        writer.add(video)
        writer.add(audio)
        guard writer.startWriting() else { throw writer.error ?? FixtureError.encoding }
        writer.startSession(atSourceTime: .zero)
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, 426, 230, kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess,
              let buffer else { throw FixtureError.encoding }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let address = CVPixelBufferGetBaseAddress(buffer) { memset(address, 0x80, CVPixelBufferGetDataSize(buffer)) }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        for frame in 0..<20 {
            try await ready(video, writer: writer)
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 10)) else {
                throw writer.error ?? FixtureError.encoding
            }
        }
        video.markAsFinished()

        var pcm = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 2, mBitsPerChannel: 16, mReserved: 0
        )
        var audioFormat: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &pcm, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &audioFormat
        ) == noErr, let audioFormat else { throw FixtureError.encoding }
        for second in 0..<2 {
            var block: CMBlockBuffer?
            guard CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: 192_000,
                blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                dataLength: 192_000, flags: 0, blockBufferOut: &block
            ) == noErr, let block else { throw FixtureError.encoding }
            guard CMBlockBufferFillDataBytes(with: 0, blockBuffer: block, offsetIntoDestination: 0, dataLength: 192_000) == noErr else {
                throw FixtureError.encoding
            }
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000),
                                          presentationTimeStamp: CMTime(value: Int64(second), timescale: 1),
                                          decodeTimeStamp: .invalid)
            var size = 4
            var sample: CMSampleBuffer?
            guard CMSampleBufferCreateReady(
                allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: audioFormat,
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
        for _ in 0..<250 {
            if input.isReadyForMoreMediaData { return }
            if writer.status == .failed { throw writer.error ?? FixtureError.encoding }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw FixtureError.encoding
    }

    private enum FixtureError: Error { case encoding }
}
#endif
