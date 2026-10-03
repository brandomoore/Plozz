import CoreGraphics
import CoreModels
import Foundation
import ImageIO
import Libass
import XCTest
@testable import EnginePlozzigen

final class ASSSubtitleRendererTests: XCTestCase {
    func testPacketNormalizationKeepsSinglePacketsAndFlattensJoinedPacketsIdentically() {
        let packets = [
            "", "0,0,Default,,0,0,0,,{\\t(0,100,\\blur10)}花\\Nflower",
            "\n", "\n0,0,Default,,0,0,0,,One\n\n1,1,Default,,0,0,0,,Two\n"
        ]
        for packet in packets {
            var events: [ASSSubtitleEvent] = []
            ASSSubtitleEvent.appendPackets(packet, start: 2, end: 4, to: &events)
            XCTAssertEqual(events, packet.split(separator: "\n").map {
                ASSSubtitleEvent(packet: String($0), start: 2, end: 4)
            })
        }
    }

    func testDirectMaskCompositingMatchesCoreGraphicsPremultipliedLayers() throws {
        let width = 17, height = 5, stride = 24
        let length = stride * (height - 1) + width
        let mask = (0..<length).map { UInt8(($0 * 37) % 256) }
        let format = CGImageAlphaInfo.premultipliedLast.rawValue
        let reference = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: format
        ))
        let direct = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: format
        ))
        let output = try XCTUnwrap(direct.data?.assumingMemoryBound(to: UInt8.self))
        let provider = try XCTUnwrap(CGDataProvider(data: Data(mask) as CFData))
        let image = try XCTUnwrap(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: stride,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: [], provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        for color: UInt32 in [0xFF000000, 0x00FF007F, 0x3972C512, 0x123456FF] {
            reference.saveGState()
            reference.clip(to: rect, mask: image)
            reference.setFillColor(
                red: CGFloat(color >> 24) / 255, green: CGFloat((color >> 16) & 255) / 255,
                blue: CGFloat((color >> 8) & 255) / 255, alpha: CGFloat(255 - (color & 255)) / 255
            )
            reference.fill(rect)
            reference.restoreGState()
            mask.withUnsafeBufferPointer {
                plozz_ass_blend_bitmap(output, direct.bytesPerRow, $0.baseAddress, stride, width, height, color)
            }
        }
        let expected = try XCTUnwrap(reference.data?.assumingMemoryBound(to: UInt8.self))
        for i in 0..<(width * height * 4) {
            XCTAssertLessThanOrEqual(abs(Int(output[i]) - Int(expected[i])), 2, "RGBA byte \(i)")
        }
    }

    private static let header = """
    [Script Info]
    ScriptType: v4.00+
    PlayResX: 640
    PlayResY: 360
    ScaledBorderAndShadow: yes
    [V4+ Styles]
    Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
    Style: Default,Arial,32,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,0,0,7,0,0,0,1
    [Events]
    Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
    """

    private func document(_ id: String = "test") -> ASSSubtitleDocument {
        .init(identity: id, header: Self.header, fonts: [], size: .init(width: 640, height: 360))
    }

    func testVectorDrawingIsRasterizedAtAuthoredPositionAndRepeatedReadOrderKeepsLayers() async throws {
        let renderer = ASSSubtitleRasterizer()
        let events = [
            ASSSubtitleEvent(packet: #"0,0,Default,,0,0,0,,{\an7\pos(100,50)\p1\c&H0000FF&}m 0 0 l 100 0 100 40 0 40"#, start: 1, end: 3),
            ASSSubtitleEvent(packet: #"0,1,Default,,0,0,0,,{\an7\pos(125,60)\p1\c&H00FF00&}m 0 0 l 30 0 30 20 0 20"#, start: 1, end: 3)
        ]
        let result = try await renderer.render(document: document(), events: events, time: 1.5)
        let image = try XCTUnwrap(result.image)
        XCTAssertEqual(image.normalizedRect.minX, 100.0 / 640, accuracy: 0.01)
        XCTAssertEqual(image.normalizedRect.minY, 50.0 / 360, accuracy: 0.01)
        XCTAssertLessThan(image.cgImage.width, 128, "Libass's padded vector bitmap must remain near the 100px drawing width.")
        let red = try pixel(image.cgImage, x: 10, y: 10)
        XCTAssertGreaterThan(red[0], 240)
        XCTAssertLessThan(red[1], 15)
        let green = try pixel(image.cgImage, x: 35, y: 20)
        XCTAssertGreaterThan(green[1], 240)
        XCTAssertLessThan(green[0], 15)
        let unchanged = try await renderer.render(document: document(), events: events, time: 1.6)
        XCTAssertFalse(unchanged.changed)
        let ended = try await renderer.render(document: document(), events: events, time: 3.5)
        XCTAssertTrue(ended.changed)
        XCTAssertNil(ended.image)
        let seekBack = try await renderer.render(document: document(), events: events, time: 1.5)
        XCTAssertNotNil(seekBack.image)
    }

    func testAnimationChangesFramesAndTrackSwitchRetiresPreviousEvents() async throws {
        let renderer = ASSSubtitleRasterizer()
        let events = [ASSSubtitleEvent(
            packet: #"0,0,Default,,0,0,0,,{\an7\move(10,20,210,20)\p1}m 0 0 l 30 0 30 30 0 30"#,
            start: 0, end: 2
        )]
        let first = try await renderer.render(document: document(), events: events, time: 0.1)
        let second = try await renderer.render(document: document(), events: events, time: 1)
        XCTAssertTrue(second.changed)
        XCTAssertGreaterThan(try XCTUnwrap(second.image).normalizedRect.minX,
                             try XCTUnwrap(first.image).normalizedRect.minX + 0.1)
        let switched = try await renderer.render(document: document("other"), events: [], time: 1)
        XCTAssertNil(switched.image)
    }

    func testJoinedEnginePacketsRenderTheSameLayersAfterActorNormalization() async throws {
        let packets = [
            #"0,0,Default,,0,0,0,,{\an7\pos(100,50)\p1\c&H0000FF&}m 0 0 l 100 0 100 40 0 40"#,
            #"0,1,Default,,0,0,0,,{\an7\pos(125,60)\p1\c&H00FF00&}m 0 0 l 30 0 30 20 0 20"#
        ]
        let renderer = ASSSubtitleRasterizer()
        let joined = try await renderer.render(document: document(), events: [
            .init(packet: packets.joined(separator: "\n"), start: 1, end: 3)
        ], time: 1.5)
        let image = try XCTUnwrap(joined.image)
        XCTAssertGreaterThan(try pixel(image.cgImage, x: 10, y: 10)[0], 240)
        XCTAssertGreaterThan(try pixel(image.cgImage, x: 35, y: 20)[1], 240)
        let repeated = try await renderer.render(document: document(), events: [
            .init(packet: packets.joined(separator: "\n"), start: 1, end: 3)
        ], time: 1.6)
        XCTAssertFalse(repeated.changed, "Replayed snapshots must not append duplicate layers")
    }

    func testPartiallyOffscreenDrawingClipsWithoutChangingItsCanvasPosition() async throws {
        let renderer = ASSSubtitleRasterizer()
        let frame = try await renderer.render(document: document(), events: [.init(
            packet: #"0,0,Default,,0,0,0,,{\an7\pos(-10,-5)\p1\c&H0000FF&}m 0 0 l 30 0 30 20 0 20"#,
            start: 0, end: 2
        )], time: 1)
        let image = try XCTUnwrap(frame.image)
        XCTAssertEqual(image.normalizedRect.minX, 0, accuracy: 0.001)
        XCTAssertEqual(image.normalizedRect.minY, 0, accuracy: 0.001)
        let color = try pixel(image.cgImage, x: 2, y: 2)
        XCTAssertGreaterThan(color[0], 240)
        XCTAssertLessThan(color[1], 15)
    }

    @MainActor
    func testDriverCoalescesBusyTicksToTheLatestAnimationTime() async throws {
        let renderer = ASSSubtitleRenderer()
        var positions: [CGFloat] = []
        renderer.onFrame = { cues in
            if case .image(let image)? = cues.first?.body { positions.append(image.normalizedRect.minX) }
        }
        renderer.update(document: document(), events: [.init(
            packet: #"0,0,Default,,0,0,0,,{\an7\move(10,20,210,20)\p1}m 0 0 l 30 0 30 30 0 30"#,
            start: 0, end: 2
        )])
        renderer.tick(0.1)
        renderer.tick(0.3)
        renderer.tick(0.5)
        renderer.tick(1)
        let deadline = ContinuousClock.now + .seconds(3)
        while positions.count < 2, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(positions.count, 2, "One in-flight render plus one latest timestamp, not a frame queue")
        XCTAssertEqual(try XCTUnwrap(positions.last), 110.0 / 640, accuracy: 0.01)
        renderer.clear()
    }

    @MainActor
    func testDriverClearsOffAndRejectsAnInFlightPreviousTrackFrame() async throws {
        let renderer = ASSSubtitleRenderer()
        var delivered: [SubtitleCue] = []
        renderer.onFrame = { delivered = $0 }
        let events = [ASSSubtitleEvent(
            packet: #"0,0,Default,,0,0,0,,{\an7\pos(20,20)\p1}m 0 0 l 60 0 60 30 0 30"#,
            start: 0, end: 2
        )]
        renderer.update(document: document(), events: events)
        renderer.tick(1)
        renderer.tick(1.5)
        renderer.clear()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(delivered.isEmpty)
        renderer.update(document: document("new"), events: events)
        renderer.tick(1)
        let deadline = ContinuousClock.now + .seconds(3)
        while delivered.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(delivered.contains(where: \.isImage))
        renderer.clear()
        XCTAssertTrue(delivered.isEmpty)
        renderer.tick(1.5)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(delivered.isEmpty)
    }

    /// Opt-in local reproduction. The copyrighted source and embedded fonts stay
    /// outside Git; ordinary runs use only the authored synthetic fixtures above.
    func testLocalASSReproduction() async throws {
        guard let path = ProcessInfo.processInfo.environment["PLOZZ_ASS_REPRO_JSON"] else {
            throw XCTSkip("Set PLOZZ_ASS_REPRO_JSON for an explicitly supplied local subtitle reproduction.")
        }
        struct Input: Decodable {
            struct Event: Decodable { let packet: String; let start: Double; let end: Double }
            struct Font: Decodable { let name: String; let path: String }
            let header: String
            let events: [Event]
            let fonts: [Font]
            let times: [Double]
            let output: String
        }
        let input = try JSONDecoder().decode(Input.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let document = ASSSubtitleDocument(
            identity: "local-reproduction", header: input.header,
            fonts: try input.fonts.map { .init(name: $0.name, data: try Data(contentsOf: URL(fileURLWithPath: $0.path))) },
            size: .init(width: 1920, height: 1080)
        )
        let renderer = ASSSubtitleRasterizer()
        let events = input.events.map { ASSSubtitleEvent(packet: $0.packet, start: $0.start, end: $0.end) }
        for time in input.times {
            let start = ContinuousClock.now
            let frame = try await renderer.render(document: document, events: events, time: time)
            guard let image = frame.image else {
                print("ASS reproduction time=\(time) no visible image changed=\(frame.changed)")
                continue
            }
            let url = URL(fileURLWithPath: input.output).appendingPathComponent("ass-\(time).png")
            let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image.cgImage, nil)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            print("ASS reproduction time=\(time) raster=\(image.cgImage.width)x\(image.cgImage.height) rect=\(image.normalizedRect) elapsed=\(start.duration(to: .now))")
        }
    }

    private func pixel(_ source: CGImage, x: Int, y: Int) throws -> [UInt8] {
        let crop = try XCTUnwrap(source.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)))
        var bytes = [UInt8](repeating: 0, count: 4)
        try bytes.withUnsafeMutableBytes {
            let context = try XCTUnwrap(CGContext(data: $0.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return bytes
    }
}
