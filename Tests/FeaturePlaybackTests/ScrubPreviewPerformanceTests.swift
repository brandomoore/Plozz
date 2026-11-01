#if canImport(UIKit)
import CoreModels
import UIKit
import XCTest
@testable import FeaturePlayback
@testable import TestSupportPerformance

@MainActor
final class ScrubPreviewPerformanceTests: XCTestCase {
    func testPerformanceGeneratedScan() async throws {
        try PerformanceProbe.requireEnabled()
        try await PerformanceProbe.measure(self, scenario: "seek-generated-80ms") {
            try await self.scanMatrix(decodeDelay: .milliseconds(80))
        }
    }

    func testPerformanceSlowGeneratedScan() async throws {
        try PerformanceProbe.requireEnabled()
        try await PerformanceProbe.measure(self, scenario: "seek-generated-180ms") {
            try await self.scanMatrix(decodeDelay: .milliseconds(180))
        }
    }

    private func scanMatrix(decodeDelay: Duration) async throws -> [String: Int] {
        var counters = [
            "stages": 0, "inputSamples": 0, "motionFrames": 0, "starvedStages": 0,
            "settledStages": 0, "decodeStarts": 0, "decodeCompletions": 0,
            "decodeCancellations": 0, "maxInFlight": 0, "blankPublications": 0,
            "maxPublicationGapMicroseconds": 0, "maxSettleMicroseconds": 0
        ]
        for direction in [-1, 1] {
            for magnitude in 1...RemoteSeekScan.rates.count {
                let extractor = PacedScrubExtractor(delay: decodeDelay)
                let coordinator = try XCTUnwrap(ScrubPreviewCoordinator(source: nil, generatedStills: extractor))
                defer {
                    coordinator.onImageChange = nil
                    coordinator.clear()
                }
                let began = ContinuousClock.now
                var previousPublication = began
                var lastImage: CGImage?
                var moving = true
                var motionFrames = 0
                var maxGap = 0
                var blanks = 0
                coordinator.onImageChange = { image in
                    guard let image else {
                        if lastImage != nil { blanks += 1 }
                        return
                    }
                    guard image !== lastImage else { return }
                    let now = ContinuousClock.now
                    maxGap = max(maxGap, Self.microseconds(previousPublication.duration(to: now)))
                    previousPublication = now
                    lastImage = image
                    if moving { motionFrames += 1 }
                }
                var position: TimeInterval = 3_600
                for _ in 0..<24 {
                    position = RemoteSeekScan.position(
                        from: position, level: direction * magnitude, elapsed: 0.033, duration: 7_200
                    )
                    coordinator.update(for: position)
                    counters["inputSamples", default: 0] += 1
                    try await Task.sleep(for: .milliseconds(33))
                }
                moving = false
                maxGap = max(maxGap, Self.microseconds(previousPublication.duration(to: .now)))
                let settledAt = ContinuousClock.now
                let finalCell = GeneratedScrubThumbnailLoader.cell(forSeconds: position)
                let deadline = settledAt + .seconds(2)
                while ContinuousClock.now < deadline {
                    if let expected = extractor.images[finalCell], coordinator.image === expected { break }
                    try await Task.sleep(for: .milliseconds(5))
                }
                let expected = try XCTUnwrap(extractor.images[finalCell], "Final target must actually decode.")
                XCTAssertTrue(coordinator.image === expected, "The final still must match the final target.")
                XCTAssertEqual(extractor.inFlight, 0)
                XCTAssertEqual(extractor.widths, [GeneratedScrubThumbnailLoader.maxWidth])
                if coordinator.image === expected { counters["settledStages", default: 0] += 1 }
                counters["stages", default: 0] += 1
                counters["motionFrames", default: 0] += motionFrames
                counters["starvedStages", default: 0] += motionFrames == 0 ? 1 : 0
                counters["decodeStarts", default: 0] += extractor.starts
                counters["decodeCompletions", default: 0] += extractor.completions
                counters["decodeCancellations", default: 0] += extractor.cancellations
                counters["blankPublications", default: 0] += blanks
                counters["maxInFlight"] = max(counters["maxInFlight", default: 0], extractor.maxInFlight)
                counters["maxPublicationGapMicroseconds"] = max(
                    counters["maxPublicationGapMicroseconds", default: 0], maxGap
                )
                counters["maxSettleMicroseconds"] = max(
                    counters["maxSettleMicroseconds", default: 0],
                    Self.microseconds(settledAt.duration(to: .now))
                )
            }
        }
        XCTAssertEqual(counters["stages"], 16)
        XCTAssertEqual(counters["inputSamples"], 384)
        XCTAssertEqual(counters["settledStages"], 16)
        XCTAssertEqual(counters["starvedStages"], 0)
        XCTAssertEqual(counters["maxInFlight"], 1)
        XCTAssertEqual(counters["decodeCancellations"], 0)
        XCTAssertEqual(counters["blankPublications"], 0)
        XCTAssertLessThanOrEqual(counters["maxPublicationGapMicroseconds", default: .max], 500_000)
        XCTAssertLessThanOrEqual(counters["maxSettleMicroseconds", default: .max], 500_000)
        return counters
    }

    private static func microseconds(_ duration: Duration) -> Int {
        let parts = duration.components
        return Int(parts.seconds * 1_000_000 + parts.attoseconds / 1_000_000_000_000)
    }
}

@MainActor
final class PacedScrubExtractor: ScrubStillExtracting {
    let delay: Duration
    var starts = 0
    var completions = 0
    var cancellations = 0
    var inFlight = 0
    var maxInFlight = 0
    var widths: Set<Int> = []
    var images: [Int: CGImage] = [:]

    init(delay: Duration) { self.delay = delay }

    func thumbnail(atSeconds seconds: TimeInterval, maxWidth: Int) async -> CGImage? {
        starts += 1
        inFlight += 1
        maxInFlight = max(maxInFlight, inFlight)
        widths.insert(maxWidth)
        defer { inFlight -= 1 }
        do {
            try await Task.sleep(for: delay)
        } catch is CancellationError {
            cancellations += 1
            return nil
        } catch {
            XCTFail("Unexpected pacing failure: \(error)")
            return nil
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: maxWidth, height: maxWidth * 9 / 16), format: format
        )
        let image = renderer.image { context in
            UIColor(hue: seconds.truncatingRemainder(dividingBy: 360) / 360,
                    saturation: 0.8, brightness: 0.8, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: maxWidth, height: maxWidth * 9 / 16))
        }.cgImage
        guard let image else {
            XCTFail("Synthetic frame creation failed.")
            return nil
        }
        images[GeneratedScrubThumbnailLoader.cell(forSeconds: seconds)] = image
        completions += 1
        return image
    }
}
#endif
