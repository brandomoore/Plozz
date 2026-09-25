#if os(tvOS)
import AVFoundation
import CoreMedia
import XCTest
import CoreModels
@testable import FeaturePlayback

@MainActor
final class NativeDisplayCriteriaTests: XCTestCase {
    private let asset = AVURLAsset(url: URL(fileURLWithPath: "/nonexistent/display-test.mp4"))

    func testPreviewCannotTakeAnAlreadyOwnedDisplay() async throws {
        let target = Target()
        let otherPlayer = try criteria(rate: 24)
        target.playbackDisplayCriteria = otherPlayer
        let desired = try criteria(rate: 60)
        var refused = false
        let controller = NativeDisplayCriteriaController(requiresUnownedTarget: true) { _ in desired }
        controller.onOwnershipConflict = { refused = true }
        controller.attach(to: target)
        controller.configure(asset: asset, fallback: nil)
        await waitFor { refused }
        controller.stop()
        XCTAssertTrue(target.playbackDisplayCriteria === otherPlayer)
        XCTAssertEqual(target.writeCount, 1)
    }

    func testPreviewRejectsAnOwnerThatArrivesWhileAssetCriteriaLoad() async throws {
        let target = Target()
        let loader = Loader()
        var refused = false
        let controller = NativeDisplayCriteriaController(requiresUnownedTarget: true, loadCriteria: loader.load)
        controller.onOwnershipConflict = { refused = true }
        controller.attach(to: target)
        controller.configure(asset: asset, fallback: nil)
        await waitFor { loader.waiters.count == 1 }
        let otherPlayer = try criteria(rate: 24)
        target.playbackDisplayCriteria = otherPlayer
        loader.finish(0, with: .success(try criteria(rate: 60)))
        await waitFor { refused }
        controller.stop()
        XCTAssertTrue(target.playbackDisplayCriteria === otherPlayer)
        XCTAssertEqual(target.writeCount, 1)
    }

    func testPreviewReportsCriteriaFailureRatherThanWaitingForever() async {
        var failed = false
        let controller = NativeDisplayCriteriaController(requiresUnownedTarget: true) { _ in
            throw URLError(.cannotDecodeContentData)
        }
        controller.onCriteriaFailure = { failed = true }
        controller.configure(asset: asset, fallback: nil)
        await waitFor { failed }
        controller.stop()
    }

    func testDefaultLoaderUsesAVFoundationsCriteriaFromAnActualAsset() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        defer { try? FileManager.default.removeItem(at: file) }
        let writer = try AVAssetWriter(outputURL: file, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input)
        XCTAssertTrue(writer.canAdd(input))
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(
            kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32ARGB, nil, &buffer), kCVReturnSuccess)
        let pixelBuffer = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let bytes = CVPixelBufferGetBaseAddress(pixelBuffer) {
            memset(bytes, 0, CVPixelBufferGetDataSize(pixelBuffer))
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        for _ in 0..<100 where !input.isReadyForMoreMediaData {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(input.isReadyForMoreMediaData)
        XCTAssertTrue(adaptor.append(pixelBuffer, withPresentationTime: .zero))
        writer.endSession(atSourceTime: CMTime(value: 1, timescale: 24))
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, "\(String(describing: writer.error))")

        let asset = AVURLAsset(url: file)
        let expected = try await asset.load(.preferredDisplayCriteria)
        let target = Target()
        let controller = NativeDisplayCriteriaController()
        defer { controller.stop() }
        controller.attach(to: target)
        controller.configure(asset: asset, fallback: nil)
        for _ in 0..<100 where target.playbackDisplayCriteria == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(target.playbackDisplayCriteria, expected)
    }

    func testAssetCriteriaReplaceTheSyntheticFallbackWithoutChangingTheAssetValue() async throws {
        let target = Target()
        let loader = Loader()
        let fallback = try criteria(rate: 24)
        let actual = try criteria(rate: 25)
        let controller = NativeDisplayCriteriaController(loadCriteria: loader.load)
        defer { controller.stop() }
        controller.attach(to: target)
        XCTAssertEqual(target.writeCount, 0, "An unloaded native surface must not write nil")
        controller.configure(asset: asset, fallback: fallback)
        XCTAssertTrue(target.playbackDisplayCriteria === fallback)
        await waitFor { loader.waiters.count == 1 }
        loader.finish(0, with: .success(actual))
        await waitFor { target.playbackDisplayCriteria === actual }
        XCTAssertEqual(target.writeCount, 2)
    }

    func testLateResolutionAfterStopCannotOverwriteAnotherEngine() async throws {
        let target = Target()
        let loader = Loader()
        let controller = NativeDisplayCriteriaController(loadCriteria: loader.load)
        controller.attach(to: target)
        controller.configure(asset: asset, fallback: try criteria(rate: 24))
        await waitFor { loader.waiters.count == 1 }
        controller.stop()
        let aetherCriteria = try criteria(rate: 60)
        target.playbackDisplayCriteria = aetherCriteria
        let writes = target.writeCount
        loader.finish(0, with: .success(try criteria(rate: 25)))
        await waitFor { loader.finished == 1 }
        controller.attach(to: target)
        XCTAssertTrue(target.playbackDisplayCriteria === aetherCriteria)
        XCTAssertEqual(target.writeCount, writes)
    }

    func testStopDoesNotClearAetherCriteriaThatReplacedItsOwn() async throws {
        let target = Target()
        let loader = Loader()
        let controller = NativeDisplayCriteriaController(loadCriteria: loader.load)
        controller.attach(to: target)
        controller.configure(asset: asset, fallback: try criteria(rate: 24))
        await waitFor { loader.waiters.count == 1 }
        let aetherCriteria = try criteria(rate: 60)
        target.playbackDisplayCriteria = aetherCriteria
        controller.stop()
        loader.finish(0, with: .failure(CancellationError()))
        await waitFor { loader.finished == 1 }
        XCTAssertTrue(target.playbackDisplayCriteria === aetherCriteria)
    }

    func testAnotherWriterDuringResolutionKeepsItsCriteria() async throws {
        let target = Target()
        let loader = Loader()
        let controller = NativeDisplayCriteriaController(loadCriteria: loader.load)
        defer { controller.stop() }
        controller.attach(to: target)
        controller.configure(asset: asset, fallback: try criteria(rate: 24))
        await waitFor { loader.waiters.count == 1 }
        let aetherCriteria = try criteria(rate: 60)
        target.playbackDisplayCriteria = aetherCriteria
        loader.finish(0, with: .success(try criteria(rate: 25)))
        await waitFor { loader.finished == 1 }
        controller.attach(to: target)
        XCTAssertTrue(target.playbackDisplayCriteria === aetherCriteria)
    }

    func testNewerLoadRejectsOlderAssetCriteria() async throws {
        let target = Target()
        let loader = Loader()
        let controller = NativeDisplayCriteriaController(loadCriteria: loader.load)
        defer { controller.stop() }
        controller.attach(to: target)
        controller.configure(asset: asset, fallback: try criteria(rate: 24))
        await waitFor { loader.waiters.count == 1 }
        controller.configure(asset: asset, fallback: try criteria(rate: 30))
        await waitFor { loader.waiters.count == 2 }
        let actual = try criteria(rate: 60)
        loader.finish(1, with: .success(actual))
        await waitFor { target.playbackDisplayCriteria === actual }
        loader.finish(0, with: .success(try criteria(rate: 25)))
        await waitFor { loader.finished == 2 }
        XCTAssertTrue(target.playbackDisplayCriteria === actual)
    }

    func testCriteriaResolvedBeforeWindowAttachmentAreAppliedOnAttachment() async throws {
        let target = Target()
        let actual = try criteria(rate: 25)
        let controller = NativeDisplayCriteriaController { _ in actual }
        defer { controller.stop() }
        controller.configure(asset: asset, fallback: nil)
        await Task.yield()
        controller.attach(to: target)
        await waitFor { target.playbackDisplayCriteria === actual }
        let writes = target.writeCount
        controller.attach(to: nil)
        controller.attach(to: target)
        XCTAssertEqual(target.writeCount, writes, "Surface remounts must not re-handshake unchanged criteria")
    }

    func testFailedAssetReadRetainsTheExistingFallback() async throws {
        let target = Target()
        let fallback = try criteria(rate: 24)
        let controller = NativeDisplayCriteriaController { _ in throw URLError(.cannotDecodeContentData) }
        defer { controller.stop() }
        controller.attach(to: target)
        controller.configure(asset: asset, fallback: fallback)
        await Task.yield()
        XCTAssertTrue(target.playbackDisplayCriteria === fallback)
    }

    func testUnknownMetadataDoesNotClearAnUnownedWindow() async throws {
        let target = Target()
        let external = try criteria(rate: 60)
        target.playbackDisplayCriteria = external
        let controller = NativeDisplayCriteriaController { _ in throw URLError(.fileDoesNotExist) }
        controller.attach(to: target)
        controller.configure(asset: asset, fallback: nil)
        await Task.yield()
        controller.stop()
        XCTAssertTrue(target.playbackDisplayCriteria === external)
    }

    func testSameRangeReloadDoesNotClearTheDisplayWhileTheNextAssetIsResolving() async throws {
        let target = Target()
        let loader = Loader()
        let fallback = try criteria(rate: 24)
        let controller = NativeDisplayCriteriaController(loadCriteria: loader.load)
        defer { controller.stop() }
        controller.attach(to: target)
        controller.configure(asset: asset, fallback: fallback)
        await waitFor { loader.waiters.count == 1 }
        controller.invalidatePendingLoad()
        let writes = target.writeCount
        controller.configure(asset: asset, fallback: fallback)
        await waitFor { loader.waiters.count == 2 }
        XCTAssertTrue(target.playbackDisplayCriteria === fallback)
        XCTAssertEqual(target.writeCount, writes)
        loader.finish(0, with: .failure(CancellationError()))
        loader.finish(1, with: .success(fallback))
        await waitFor { loader.finished == 2 }
    }

    func testStopClearsOnlyTheCriteriaThisControllerWrote() async throws {
        let target = Target()
        let actual = try criteria(rate: 24)
        let controller = NativeDisplayCriteriaController { _ in actual }
        controller.attach(to: target)
        controller.configure(asset: asset, fallback: nil)
        await waitFor { target.playbackDisplayCriteria === actual }
        controller.stop()
        XCTAssertNil(target.playbackDisplayCriteria)
    }

    func testMovingToAnotherWindowRetiresOnlyItsOwnPreviousRequest() async throws {
        let original = Target()
        let next = Target()
        let actual = try criteria(rate: 24)
        let controller = NativeDisplayCriteriaController { _ in actual }
        defer { controller.stop() }
        controller.attach(to: original)
        controller.configure(asset: asset, fallback: nil)
        await waitFor { original.playbackDisplayCriteria === actual }
        controller.attach(to: next)
        XCTAssertNil(original.playbackDisplayCriteria)
        XCTAssertTrue(next.playbackDisplayCriteria === actual)
    }

    private func waitFor(_ condition: () -> Bool) async {
        for _ in 0..<100 where !condition() { await Task.yield() }
        XCTAssertTrue(condition())
    }

    private func criteria(rate: Float) throws -> AVDisplayCriteria {
        var description: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, codecType: kCMVideoCodecType_HEVC,
            width: 3840, height: 2160, extensions: nil, formatDescriptionOut: &description)
        XCTAssertEqual(status, noErr)
        return AVDisplayCriteria(refreshRate: rate, formatDescription: try XCTUnwrap(description))
    }

    @MainActor
    private final class Target: NativeDisplayCriteriaTarget {
        var writeCount = 0
        var playbackDisplayCriteria: AVDisplayCriteria? { didSet { writeCount += 1 } }
    }

    @MainActor
    private final class Loader {
        var waiters: [CheckedContinuation<AVDisplayCriteria, Error>] = []
        var finished = 0
        func load(_ asset: AVAsset) async throws -> AVDisplayCriteria {
            defer { finished += 1 }
            return try await withCheckedThrowingContinuation { waiters.append($0) }
        }
        func finish(_ index: Int, with result: Result<AVDisplayCriteria, Error>) {
            waiters[index].resume(with: result)
        }
    }

    // MARK: Source-hint bootstrap (#58)

    func testHDR10PlusRequestsNoSyntheticBootstrapCriteria() {
        let metadata = MediaSourceMetadata(
            video: .init(codec: "hevc", width: 3840, height: 2160, videoRangeType: "HDR10Plus"))
        XCTAssertNil(nativeBootstrapDisplayCriteria(metadata: metadata))
    }

    func testOtherHDRSourcesKeepTheirBootstrapCriteria() {
        for range in ["HDR10", "DOVI", "HLG"] {
            let metadata = MediaSourceMetadata(
                video: .init(codec: "hevc", width: 3840, height: 2160, videoRangeType: range))
            XCTAssertNotNil(nativeBootstrapDisplayCriteria(metadata: metadata), range)
        }
        XCTAssertNil(nativeBootstrapDisplayCriteria(metadata: .init(
            video: .init(codec: "h264", videoRangeType: "SDR"))))
    }
}
#endif
