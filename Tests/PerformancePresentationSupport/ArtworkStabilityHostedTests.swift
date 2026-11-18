import CoreModels
import CoreUI
import Observation
import SwiftUI
import UIKit
import XCTest

@MainActor
final class ArtworkStabilityHostedTests: XCTestCase {
    func testLateCandidatesCannotReplacePaintedArtwork() async throws {
        let fixture = try await Fixture()
        defer { fixture.close() }
        fixture.model.references = [.remote(fixture.first)]
        fixture.mount()
        try await waitUntil { fixture.model.selected == .remote(fixture.first) }
        fixture.model.references = [.remote(fixture.second), .remote(fixture.first)]
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(fixture.model.selected, .remote(fixture.first))
        XCTAssertEqual(fixture.model.distinctSelections, [.remote(fixture.first)])
        try fixture.assertRedImage()
    }

    func testPreferredSourceWaitsRatherThanPaintingCachedLibraryFallback() async throws {
        let fixture = try await Fixture()
        defer { fixture.close() }
        _ = await ArtworkImageCache.shared.image(for: fixture.first, variant: .landscapeCard)
        fixture.model.references = [.remote(fixture.first)]
        fixture.model.preference = .online
        let gate = OnlineGate()
        fixture.model.lookup = { await gate.value() }
        fixture.mount()
        try await waitUntil { fixture.model.lookups == 1 }
        XCTAssertNil(fixture.model.selected)
        await gate.finish(fixture.second)
        try await waitUntil { fixture.model.selected == .remote(fixture.second) }
        XCTAssertEqual(fixture.model.distinctSelections, [.remote(fixture.second)])
    }

    func testSubjectAndPreferenceChangesResolveAgain() async throws {
        let fixture = try await Fixture()
        defer { fixture.close() }
        fixture.model.references = [.remote(fixture.first)]
        let preferred = fixture.second
        fixture.model.lookup = { preferred }
        fixture.mount()
        try await waitUntil { fixture.model.selected == .remote(fixture.first) }
        fixture.model.preference = .online
        try await waitUntil { fixture.model.selected == .remote(fixture.second) }
        fixture.model.preference = .library
        fixture.model.subject = "another-title"
        fixture.model.references = [.remote(fixture.first)]
        try await waitUntil { fixture.model.selected == .remote(fixture.first) }
        try fixture.assertRedImage()
    }

    func testPerformanceFirstPaintAndLateMetadata() async throws {
        try PerformanceProbe.requireEnabled()
        try await PerformanceProbe.measure(self, scenario: "artwork-first-paint") {
            let fixture = try await Fixture()
            defer { fixture.close() }
            fixture.model.preference = .online
            fixture.model.references = [.remote(fixture.first)]
            let preferred = fixture.second
            fixture.model.lookup = {
                try? await Task.sleep(for: .milliseconds(150))
                return Task.isCancelled ? nil : preferred
            }
            let start = ContinuousClock.now
            fixture.mount()
            try await waitUntil { fixture.model.selected == .remote(preferred) }
            let firstPaint = start.duration(to: .now).components
            for index in 0..<12 {
                fixture.model.references = index.isMultiple(of: 2)
                    ? [.remote(fixture.first), .remote(preferred)]
                    : [.remote(preferred), .remote(fixture.first)]
                try await Task.sleep(for: .milliseconds(20))
            }
            return [
                "mountedImages": 1,
                "metadataUpdates": 12,
                "sourceLookups": fixture.model.lookups,
                "distinctSelections": fixture.model.distinctSelections.count,
                "firstPaintMicroseconds": Int(firstPaint.seconds * 1_000_000 + firstPaint.attoseconds / 1_000_000_000_000)
            ]
        }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), "Artwork did not reach the required state.")
    }

    private actor OnlineGate {
        private var result: URL?
        func value() async -> URL? {
            while result == nil, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(10))
            }
            return Task.isCancelled ? nil : result
        }
        func finish(_ url: URL) {
            result = url
        }
    }

    @MainActor @Observable
    final class Model {
        var references: [ArtworkReference] = []
        var preference = ArtworkPreference.library
        var subject = UUID().uuidString
        var lookup: (@Sendable () async -> URL?)?
        var selected: ArtworkReference?
        var distinctSelections: [ArtworkReference] = []
        var lookups = 0
    }

    private struct Artwork: View {
        let model: Model
        var body: some View {
            FallbackAsyncImage(
                references: model.references, variant: .landscapeCard,
                artworkPolicy: .init(area: .details, settings: .init(preference: model.preference)),
                asyncFallbackURL: model.lookup.map { lookup in
                    {
                        await MainActor.run { model.lookups += 1 }
                        return await lookup()
                    }
                },
                onResolveReference: { reference in
                    model.selected = reference
                    if let reference, model.distinctSelections.last != reference {
                        model.distinctSelections.append(reference)
                    }
                },
                pinIdentity: model.subject
            ) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Color.black
            }
            .frame(width: 160, height: 90)
        }
    }

    @MainActor
    private final class Fixture {
        let model = Model()
        let directory: URL
        let first: URL
        let second: URL
        let window: UIWindow
        let previous: UIWindow?
        var host: UIHostingController<Artwork>?

        init() async throws {
            let deadline = ContinuousClock.now + .seconds(5)
            while !UIApplication.shared.connectedScenes.contains(where: { $0.activationState == .foregroundActive }),
                  ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .first { $0.activationState == .foregroundActive })
            previous = scene.windows.first(where: \.isKeyWindow)
            window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 160, height: 90)
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            first = directory.appendingPathComponent("first.png")
            second = directory.appendingPathComponent("second.png")
            for (url, color) in [(first, UIColor.red), (second, UIColor.blue)] {
                let image = UIGraphicsImageRenderer(size: CGSize(width: 160, height: 90)).image {
                    color.setFill()
                    $0.fill(CGRect(x: 0, y: 0, width: 160, height: 90))
                }
                try XCTUnwrap(image.pngData()).write(to: url)
            }
        }

        func mount() {
            let host = UIHostingController(rootView: Artwork(model: model))
            self.host = host
            window.rootViewController = host
            window.makeKeyAndVisible()
            window.layoutIfNeeded()
        }

        func assertRedImage(file: StaticString = #filePath, line: UInt = #line) throws {
            window.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image {
                window.layer.render(in: $0.cgContext)
            }
            let rendered = try XCTUnwrap(image.cgImage)
            let center = try XCTUnwrap(rendered.cropping(to: CGRect(
                x: rendered.width / 2, y: rendered.height / 2, width: 1, height: 1
            )))
            var pixel = [UInt8](repeating: 0, count: 4)
            try pixel.withUnsafeMutableBytes { bytes in
                let context = try XCTUnwrap(CGContext(
                    data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                ))
                context.draw(center, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            }
            XCTAssertGreaterThan(pixel[0], 200, file: file, line: line)
            XCTAssertLessThan(pixel[2], 30, file: file, line: line)
        }

        func close() {
            window.isHidden = true
            window.rootViewController = nil
            host = nil
            previous?.makeKeyAndVisible()
            do { try FileManager.default.removeItem(at: directory) }
            catch { XCTFail("Could not remove owned artwork fixture: \(error)") }
        }
    }
}
