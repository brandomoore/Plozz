import CoreGraphics
import CoreModels
import CoreNetworking
import Foundation
import SwiftLibass

struct ASSSubtitleEvent: Hashable, Sendable {
    let packet: String
    let start: Double
    let end: Double
}

struct ASSSubtitleFont: Sendable {
    let name: String
    let data: Data
}

struct ASSSubtitleDocument: Sendable {
    let identity: String
    let header: String
    let fonts: [ASSSubtitleFont]
    let size: CGSize
}

enum ASSSubtitleRenderError: Error {
    case initialization, invalidCanvas, invalidBitmap, allocation
}

/// Libass state never leaves this actor. Rendering is admitted one frame at a
/// time by the driver, so expensive karaoke cannot queue behind the video clock.
actor ASSSubtitleRasterizer {
    private var context: Context?
    private var identity: String?
    private var events: Set<ASSSubtitleEvent> = []
    private var eventBytes = 0
    private var lastTime: Double?

    struct Frame: Sendable {
        let changed: Bool
        let image: SubtitleImage?
    }

    func render(document: ASSSubtitleDocument, events incoming: [ASSSubtitleEvent], time: Double) throws -> Frame {
        guard time.isFinite, abs(time) < Double(Int64.max) / 2_000 else { throw ASSSubtitleRenderError.invalidCanvas }
        if identity != document.identity {
            context = try Context(document: document)
            identity = document.identity
            events.removeAll(keepingCapacity: true)
            eventBytes = 0
            lastTime = nil
        }
        guard let context else { throw ASSSubtitleRenderError.initialization }
        let movedBackward = lastTime.map { time < $0 - 0.1 } ?? false
        let prunable = events.count > 4_000 && events.contains { $0.end < time - 5 }
        if movedBackward || prunable {
            let retained = movedBackward ? [] : events.filter { $0.end >= time - 5 }
            ass_flush_events(context.track)
            events.removeAll(keepingCapacity: true)
            eventBytes = 0
            for event in retained {
                try context.append(event)
                events.insert(event)
                eventBytes += event.packet.utf8.count
            }
        }
        lastTime = time
        for event in incoming where event.start.isFinite && event.end.isFinite
            && event.end > event.start && event.end >= time - 5 && event.start <= time + 10 {
            guard events.insert(event).inserted else { continue }
            eventBytes += event.packet.utf8.count
            guard events.count <= 30_000, eventBytes <= 32 * 1_024 * 1_024 else {
                throw ASSSubtitleRenderError.allocation
            }
            try context.append(event)
        }
        var changed: Int32 = 0
        let images = ass_render_frame(context.renderer, context.track, Int64((time * 1_000).rounded()), &changed)
        guard changed != 0 else { return Frame(changed: false, image: nil) }
        return Frame(changed: true, image: try context.composite(images))
    }

    private final class Context {
        let library: OpaquePointer
        let renderer: OpaquePointer
        let track: UnsafeMutablePointer<ASS_Track>
        let size: CGSize

        init(document: ASSSubtitleDocument) throws {
            guard document.size.width > 0, document.size.height > 0,
                  document.size.width <= 3_840, document.size.height <= 2_160 else {
                throw ASSSubtitleRenderError.invalidCanvas
            }
            guard document.header.utf8.count <= 4 * 1_024 * 1_024,
                  document.fonts.count <= 128,
                  document.fonts.allSatisfy({ $0.data.count <= 32 * 1_024 * 1_024 }),
                  document.fonts.reduce(0, { $0 + $1.data.count }) <= 128 * 1_024 * 1_024 else {
                throw ASSSubtitleRenderError.allocation
            }
            guard let library = ass_library_init() else { throw ASSSubtitleRenderError.initialization }
            // Native diagnostics may contain embedded font names or subtitle text.
            ass_set_message_cb(library, { _, _, _, _ in }, nil)
            guard let renderer = ass_renderer_init(library) else {
                ass_library_done(library)
                throw ASSSubtitleRenderError.initialization
            }
            guard let track = ass_new_track(library) else {
                ass_renderer_done(renderer)
                ass_library_done(library)
                throw ASSSubtitleRenderError.initialization
            }
            self.library = library
            self.renderer = renderer
            self.track = track
            ass_set_check_readorder(track, 0)
            size = document.size
            ass_set_frame_size(renderer, Int32(size.width), Int32(size.height))
            ass_set_storage_size(renderer, Int32(size.width), Int32(size.height))
            ass_set_cache_limits(renderer, 1_000, 64)
            for font in document.fonts where !font.data.isEmpty && font.data.count <= 32 * 1_024 * 1_024 {
                font.name.withCString { name in
                    font.data.withUnsafeBytes {
                        ass_add_font(library, name, $0.bindMemory(to: CChar.self).baseAddress, Int32(font.data.count))
                    }
                }
            }
            ass_set_fonts(renderer, nil, "Arial", Int32(ASS_FONTPROVIDER_CORETEXT.rawValue), nil, 1)
            var header = Array(document.header.replacingOccurrences(of: "\0", with: "").utf8CString)
            let count = header.count - 1
            header.withUnsafeMutableBufferPointer {
                ass_process_codec_private(track, $0.baseAddress, Int32(count))
            }
        }

        deinit {
            ass_free_track(track)
            ass_renderer_done(renderer)
            ass_library_done(library)
        }

        func append(_ event: ASSSubtitleEvent) throws {
            guard event.packet.utf8.count < 1_000_000,
                  abs(event.start) < Double(Int64.max) / 2_000,
                  event.end - event.start < Double(Int64.max) / 2_000 else {
                throw ASSSubtitleRenderError.invalidBitmap
            }
            var packet = Array(event.packet.utf8CString)
            let count = packet.count - 1
            packet.withUnsafeMutableBufferPointer {
                ass_process_chunk(track, $0.baseAddress, Int32(count),
                                  Int64((event.start * 1_000).rounded()), Int64(((event.end - event.start) * 1_000).rounded()))
            }
        }

        func composite(_ first: UnsafeMutablePointer<ASS_Image>?) throws -> SubtitleImage? {
            let canvas = CGRect(origin: .zero, size: size)
            var bounds = CGRect.null
            var pointer = first
            while let image = pointer?.pointee {
                if image.w > 0, image.h > 0 {
                    bounds = bounds.union(CGRect(x: Int(image.dst_x), y: Int(image.dst_y),
                                                width: Int(image.w), height: Int(image.h)).intersection(canvas))
                }
                pointer = image.next
            }
            guard !bounds.isNull, !bounds.isEmpty else { return nil }
            bounds = bounds.integral
            guard let context = CGContext(
                data: nil, width: Int(bounds.width), height: Int(bounds.height),
                bitsPerComponent: 8, bytesPerRow: Int(bounds.width) * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { throw ASSSubtitleRenderError.allocation }
            pointer = first
            while let image = pointer?.pointee {
                defer { pointer = image.next }
                guard image.w > 0, image.h > 0 else { continue }
                let rect = CGRect(x: Int(image.dst_x), y: Int(image.dst_y), width: Int(image.w), height: Int(image.h))
                guard rect.intersects(canvas) else { continue }
                guard let bitmap = image.bitmap, image.stride >= image.w,
                      image.w <= 16_384, image.h <= 16_384,
                      Int64(image.stride) * Int64(image.h) <= 64 * 1_024 * 1_024 else {
                    throw ASSSubtitleRenderError.invalidBitmap
                }
                // libass's final row is not necessarily padded to stride.
                let count = Int(image.stride) * (Int(image.h) - 1) + Int(image.w)
                let data = Data(bytes: bitmap, count: count)
                guard let provider = CGDataProvider(data: data as CFData),
                      let mask = CGImage(
                        width: Int(image.w), height: Int(image.h), bitsPerComponent: 8,
                        bitsPerPixel: 8, bytesPerRow: Int(image.stride),
                        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: [],
                        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
                      ) else { throw ASSSubtitleRenderError.invalidBitmap }
                let color = image.color
                let target = CGRect(x: rect.minX - bounds.minX, y: bounds.maxY - rect.maxY,
                                    width: rect.width, height: rect.height)
                context.saveGState()
                context.clip(to: target, mask: mask)
                context.setFillColor(red: CGFloat((color >> 24) & 255) / 255,
                                     green: CGFloat((color >> 16) & 255) / 255,
                                     blue: CGFloat((color >> 8) & 255) / 255,
                                     alpha: CGFloat(255 - (color & 255)) / 255)
                context.fill(target)
                context.restoreGState()
            }
            guard let image = context.makeImage() else { throw ASSSubtitleRenderError.allocation }
            return SubtitleImage(cgImage: image,
                                 normalizedRect: CGRect(x: bounds.minX / size.width, y: bounds.minY / size.height,
                                                        width: bounds.width / size.width, height: bounds.height / size.height),
                                 canvasSize: size)
        }
    }
}

@MainActor
final class ASSSubtitleRenderer {
    private var rasterizer = ASSSubtitleRasterizer()
    private var document: ASSSubtitleDocument?
    private var events: [ASSSubtitleEvent] = []
    private var revision = 0
    private var frameID = 0
    private var pending: Task<Void, Never>?
    private var lastTime: Double?
    private var failed = false
    var onFrame: (([SubtitleCue]) -> Void)?

    func update(document: ASSSubtitleDocument, events: [ASSSubtitleEvent]) {
        if self.document?.identity != document.identity || events.isEmpty { clear() }
        self.document = document
        self.events = events
        lastTime = nil
    }

    func tick(_ time: Double) {
        guard !failed, pending == nil, let document, time.isFinite,
              lastTime.map({ abs(time - $0) >= 1.0 / 60 }) ?? true else { return }
        lastTime = time
        let revision = revision, events = events, rasterizer = rasterizer
        pending = Task { [weak self] in
            do {
                let frame = try await rasterizer.render(document: document, events: events, time: time)
                guard let self, !Task.isCancelled, self.revision == revision else { return }
                pending = nil
                guard frame.changed else { return }
                frameID &+= 1
                onFrame?(frame.image.map {
                    [SubtitleCue(id: frameID, start: 0, end: .greatestFiniteMagnitude, body: .image($0))]
                } ?? [])
            } catch {
                guard let self, !Task.isCancelled, self.revision == revision else { return }
                pending = nil
                failed = true
                onFrame?([])
                PlozzLog.playback.error("ASS subtitle rendering failed: \(String(describing: error))")
            }
        }
    }

    func clear() {
        revision &+= 1
        pending?.cancel()
        pending = nil
        document = nil
        events = []
        lastTime = nil
        failed = false
        rasterizer = ASSSubtitleRasterizer()
        onFrame?([])
    }
}
