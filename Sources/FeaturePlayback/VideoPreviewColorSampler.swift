#if os(iOS)
import AVFoundation
import CoreImage
import UIKit

/// Elective 2 Hz analysis of the existing decoder, never another player or demuxer.
@MainActor
final class VideoPreviewColorSampler {
    private weak var engine: (any VideoEngine)?
    private var task: Task<Void, Never>?
    private var item: AVPlayerItem?
    private var output: AVPlayerItemVideoOutput?
    private var sourceID: ObjectIdentifier?
    private var sourceGeneration: UInt64?
    private var generation = 0
    private var lastTime: TimeInterval?
    private var worker: VideoPreviewColorWorker?
    private var sampleInFlight = false
    private let publish: ([SIMD4<Float>]) -> Void
    private(set) var sampleCount = 0
    var isRunning: Bool { task != nil }

    init(publish: @escaping ([SIMD4<Float>]) -> Void) {
        self.publish = publish
    }

    deinit {
        task?.cancel()
        if let item, let output { item.remove(output) }
    }

    func update(engine: any VideoEngine, enabled: Bool) {
        if self.engine !== engine {
            stop()
            self.engine = engine
        }
        guard enabled else { stop(); return }
        guard task == nil else { return }
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard self != nil else { return }
                await self?.sample()
                do { try await Task.sleep(for: .milliseconds(500)) }
                catch { return }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        generation &+= 1
        detach()
        if !sampleInFlight { worker = nil }
        publish([])
    }

    private func detach() {
        if let item, let output { item.remove(output) }
        item = nil
        output = nil
        sourceID = nil
        sourceGeneration = nil
        lastTime = nil
    }

    private func sample() async {
        guard !sampleInFlight else { return }
        guard let engine, engine.hasPresentedVideoFrame else {
            if sourceID != nil { detach(); publish([]) }
            return
        }
        let currentItem = engine.nowPlayingPlayer?.currentItem
        let currentID = currentItem.map(ObjectIdentifier.init) ?? ObjectIdentifier(engine)
        let frameGeneration = engine.previewFrameGeneration
        if sourceID != currentID || sourceGeneration != frameGeneration {
            detach()
            publish([])
            sourceID = currentID
            sourceGeneration = frameGeneration
            if let currentItem {
                // Keep the native pixel format: do not request a full-size BGRA conversion on every frame.
                let newOutput = AVPlayerItemVideoOutput(outputSettings: nil)
                newOutput.suppressesPlayerRendering = false
                currentItem.add(newOutput)
                item = currentItem
                output = newOutput
                return
            }
        }
        let time = engine.nowPlayingPlayer?.currentTime().seconds ?? engine.currentTime
        if let lastTime, abs(time - lastTime) < 0.1 { return }
        let buffer: CVPixelBuffer?
        if let output, let player = engine.nowPlayingPlayer {
            let itemTime = player.currentTime()
            guard output.hasNewPixelBuffer(forItemTime: itemTime) else { return }
            buffer = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil)
        } else {
            buffer = engine.previewVideoFrame()
        }
        guard let buffer else { return }
        let ticket = generation
        let sampler = worker ?? VideoPreviewColorWorker()
        worker = sampler
        sampleInFlight = true
        defer {
            sampleInFlight = false
            if task == nil { worker = nil }
        }
        let colors = await sampler.colors(in: CIImage(cvPixelBuffer: buffer))
        guard !Task.isCancelled, generation == ticket, self.engine === engine,
              engine.hasPresentedVideoFrame, engine.previewFrameGeneration == frameGeneration,
              engine.nowPlayingPlayer?.currentItem === currentItem else { return }
        lastTime = time
        sampleCount += 1
        publish(colors)
    }
}

actor VideoPreviewColorWorker {
    private let context = CIContext(options: [.cacheIntermediates: false, .priorityRequestLow: true])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    static let width = 24
    static let height = 14

    func colors(in image: CIImage) -> [SIMD4<Float>] {
        guard !Task.isCancelled, image.extent.width > 0, image.extent.height > 0,
              !image.extent.isInfinite else { return [] }
        let small = image.transformed(by: CGAffineTransform(
            scaleX: CGFloat(Self.width) / image.extent.width,
            y: CGFloat(Self.height) / image.extent.height
        ))
        var pixels = [UInt8](repeating: 0, count: Self.width * Self.height * 4)
        context.render(small, toBitmap: &pixels, rowBytes: Self.width * 4,
                       bounds: CGRect(x: 0, y: 0, width: Self.width, height: Self.height),
                       format: .RGBA8, colorSpace: colorSpace)
        return Self.palette(pixels)
    }

    /// Normalize chromatic pixels before averaging so dim hues do not become a gray shadow.
    nonisolated static func palette(_ pixels: [UInt8]) -> [SIMD4<Float>] {
        precondition(pixels.count == width * height * 4)
        return (0..<3).map { zone in
            var sum = SIMD3<Float>.zero
            var weight: Float = 0
            for y in 0..<height {
                for x in (zone * 8)..<((zone + 1) * 8) {
                    let offset = (y * width + x) * 4
                    let rgb = SIMD3<Float>(
                        Float(pixels[offset]), Float(pixels[offset + 1]), Float(pixels[offset + 2])
                    ) / 255
                    let maximum = max(rgb.x, rgb.y, rgb.z)
                    let minimum = min(rgb.x, rgb.y, rgb.z)
                    guard maximum > 0.025 else { continue }
                    let saturation = (maximum - minimum) / maximum
                    guard saturation > 0.08 else { continue }
                    sum += rgb / maximum * saturation
                    weight += saturation
                }
            }
            guard weight > 0 else { return .zero }
            let rgb = sum / weight
            let maximum = max(rgb.x, rgb.y, rgb.z)
            let lifted = SIMD3<Float>(repeating: 1) - (SIMD3<Float>(repeating: 1) - rgb / maximum) * 0.48
            let coverage = min(1, weight / Float(8 * height) * 4)
            return SIMD4(lifted.x, lifted.y, lifted.z, 0.9 * coverage)
        }
    }
}
#endif
