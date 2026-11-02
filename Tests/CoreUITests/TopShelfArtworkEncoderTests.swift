#if canImport(UIKit)
@testable import TopShelfKit
import UIKit
import XCTest

final class TopShelfArtworkEncoderTests: XCTestCase {
    @MainActor
    func testMainActorResolverCompressesOnWorkerAndPreservesImageFormats() async throws {
        let image = fixture()
        let encoder = TopShelfArtworkEncoder { image, format in
            XCTAssertFalse(Thread.isMainThread, "Top Shelf compression must not block remote input")
            switch format {
            case .png: return image.pngData()
            case .jpeg: return image.jpegData(compressionQuality: 0.9)
            }
        }
        for format in [TopShelfArtworkEncoder.Format.png, .jpeg] {
            let result = await encoder.data(for: image, format: format)
            let data = try XCTUnwrap(result)
            let decoded = try XCTUnwrap(UIImage(data: data))
            XCTAssertEqual(decoded.size, image.size)
            switch format {
            case .png: XCTAssertEqual(Array(data.prefix(4)), [0x89, 0x50, 0x4e, 0x47])
            case .jpeg: XCTAssertEqual(Array(data.prefix(2)), [0xff, 0xd8])
            }
        }
    }

    @MainActor
    func testCancelledResolutionDoesNotStartCompression() async {
        let image = fixture()
        let encoder = TopShelfArtworkEncoder { _, _ in
            XCTFail("Cancelled artwork must not start compression")
            return nil
        }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await encoder.data(for: image, format: .png)
        }
        let result = await task.value
        XCTAssertNil(result)
    }

    @MainActor
    func testCancellationDuringCompressionDiscardsEncodedData() async {
        let image = fixture()
        let encoder = TopShelfArtworkEncoder { image, _ in
            withUnsafeCurrentTask { $0?.cancel() }
            return image.pngData()
        }
        let task = Task { await encoder.data(for: image, format: .png) }
        let result = await task.value
        XCTAssertNil(result)
    }

    @MainActor
    private func fixture() -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 60, height: 90), format: format).image {
            UIColor.red.setFill()
            $0.fill(CGRect(x: 0, y: 0, width: 60, height: 90))
        }
    }
}
#endif
