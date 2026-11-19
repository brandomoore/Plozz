#if PLOZZ_FRAME_ASS
import AetherEngine
import Foundation
import Libass

/// One libass session per registration; only the decode callback enters it.
/// Retain the current overlaps and artwork, never a table of future frames.
final class FrameASSArtwork: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64?
    private var context: ASSSubtitleRasterizer.Context?
    private var events: [ASSSubtitleEvent] = []
    private var images: [SubtitleImage] = []

    func resolve(_ frame: SoftwareASSFrame) -> SoftwareASSArtwork {
        lock.withLock {
            guard let packets = frame.packets, frame.subtitleSeconds.isFinite,
                  abs(frame.subtitleSeconds) < Double(Int64.max) / 2_000 else { return .notReady }
            do {
                if frame.generation != generation || context?.size != frame.canvas {
                    guard let header = frame.track.assHeader else { return .notReady }
                    context = try .init(document: .init(identity: String(frame.track.id), header: header,
                        fonts: frame.fonts.map { .init(name: $0.filename, data: $0.data) }, size: frame.canvas))
                    generation = frame.generation
                    events = []
                    images = []
                }
                guard let context else { return .notReady }
                let active = try packets.map { packet -> ASSSubtitleEvent in
                    guard let text = String(data: packet.data, encoding: .utf8) else {
                        throw ASSSubtitleRenderError.invalidBitmap
                    }
                    return .init(packet: text, start: packet.start, end: packet.start + packet.duration)
                }
                if active != events {
                    ass_flush_events(context.track)
                    for event in active { try context.append(event) }
                    events = active
                }
                var changed: Int32 = 0
                let head = ass_render_frame(context.renderer, context.track,
                                            Int64((frame.subtitleSeconds * 1_000).rounded()), &changed)
                if changed != 0 || head == nil {
                    images = try context.composite(head).map {
                        .init(cgImage: $0.cgImage, position: $0.normalizedRect, canvasSize: $0.canvasSize)
                    }
                }
                return images.isEmpty ? .clear : .images(images)
            } catch {
                context = nil
                return .notReady
            }
        }
    }
}
#endif
