import CoreGraphics
import CoreImage
import SwiftUI
import XCTest
@testable import CoreUI

final class QRCodeRenderingTests: XCTestCase {
    @MainActor
    func testRepeatedBodyEvaluation() {
        let start = ContinuousClock.now
        for _ in 0..<24 {
            withExtendedLifetime(QRCodeView("https://example.test/activate?code=fixture").body) {}
        }
        print("QR unchanged body: 24 evaluations; elapsed: \(start.duration(to: .now))")
    }

    func testCachedPixelsAreReusedAndEveryInputAffectsTheKey() async throws {
        let store = QRCodeImageStore()
        let request = QRCodeImageRequest(content: "https://example.test/first")
        let first = try await store.image(for: request)
        let repeated = try await store.image(for: request)
        XCTAssertTrue(first === repeated)
        let otherContent = try await store.image(for: .init(content: "https://example.test/second"))
        let otherCorrection = try await store.image(for: .init(content: request.content, correctionLevel: .high))
        let mask = try await store.image(for: .init(content: request.content, transparentBackground: true))
        XCTAssertFalse(first === otherContent)
        XCTAssertFalse(first === otherCorrection)
        XCTAssertFalse(first === mask)
    }

    func testCacheEvictsOldPayloadsRatherThanGrowingIndefinitely() async throws {
        let store = QRCodeImageStore()
        let request = QRCodeImageRequest(content: "https://example.test/old")
        let first = try await store.image(for: request)
        for index in 0..<12 {
            _ = try await store.image(for: .init(content: "https://example.test/\(index)"))
        }
        let rebuilt = try await store.image(for: request)
        XCTAssertFalse(first === rebuilt)
    }

    func testConcurrentRequestsShareOneRenderedImage() async throws {
        let store = QRCodeImageStore()
        let request = QRCodeImageRequest(content: "https://example.test/shared")
        async let first = store.image(for: request)
        async let second = store.image(for: request)
        let images = try await (first, second)
        XCTAssertTrue(images.0 === images.1)
    }

    func testPixelBudgetEvictsBeforeTheEntryLimitAndDoesNotCacheOversizedImages() async throws {
        let store = QRCodeImageStore()
        let budget = 16 * 1_024 * 1_024
        let payload = String(repeating: "x", count: 1_200)
        let request = QRCodeImageRequest(content: payload + "0")
        let first = try await store.image(for: request)
        let cost = first.bytesPerRow * first.height
        XCTAssertLessThan(cost, budget)
        let additionalEntries = budget / cost
        XCTAssertLessThan(additionalEntries + 1, 8, "Exercise the pixel budget, not the entry limit.")
        for index in 1...additionalEntries {
            _ = try await store.image(for: .init(content: payload + String(index)))
        }
        let rebuilt = try await store.image(for: request)
        XCTAssertFalse(first === rebuilt)

        let oversized = QRCodeImageRequest(content: String(repeating: "x", count: 2_000))
        let large = try await store.image(for: oversized)
        XCTAssertGreaterThan(large.bytesPerRow * large.height, budget)
        let repeated = try await store.image(for: oversized)
        XCTAssertFalse(large === repeated, "A single oversized image must not enter the shared cache.")
    }

    func testCancelledRequestDoesNotRender() async throws {
        let store = QRCodeImageStore()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await store.image(for: .init(content: "cancelled"))
        }
        do {
            _ = try await task.value
            XCTFail("Cancelled QR work must not generate or publish an image.")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testAllCorrectionLevelsAndTransparentMaskEncodeTheExactPayload() async throws {
        let store = QRCodeImageStore()
        let payload = "https://example.test/setup?code=fixture-123"
        let detector = try XCTUnwrap(CIDetector(
            ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
        ))
        for level in [QRCodeCorrectionLevel.low, .medium, .quartile, .high] {
            for transparent in [false, true] {
                let bitmap = try await store.image(for: .init(
                    content: payload, correctionLevel: level, transparentBackground: transparent
                ))
                let image = CIImage(cgImage: bitmap)
                let background = CIImage(color: CIColor.white).cropped(to: image.extent)
                let codes = detector.features(in: image.composited(over: background))
                    .compactMap { ($0 as? CIQRCodeFeature)?.messageString }
                XCTAssertEqual(codes, [payload])
            }
        }
    }

    func testUnencodablePayloadThrowsAndDoesNotPoisonLaterRequests() async throws {
        let store = QRCodeImageStore()
        do {
            _ = try await store.image(for: .init(content: String(repeating: "x", count: 5_000)))
            XCTFail("An unencodable payload must fail explicitly.")
        } catch {
            XCTAssertTrue(error is QRCodeImageStore.RenderingError)
        }
        let image = try await store.image(for: .init(content: "valid"))
        XCTAssertGreaterThan(image.width, 0)
    }
}
