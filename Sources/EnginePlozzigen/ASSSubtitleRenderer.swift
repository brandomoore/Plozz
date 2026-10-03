import CoreGraphics
import CoreModels
import CoreNetworking
import Foundation
import Libass

struct ASSSubtitleEvent: Hashable, Sendable {
    let packet: String
    let start: Double
    let end: Double

    static func appendPackets(_ packet: String, start: Double, end: Double, to events: inout [Self]) {
        guard !packet.isEmpty else { return }
        // Aether normally emits one packet per cue. Splitting every long override
        // string into Characters and rebuilding it stalls the presentation thread.
        if !packet.utf8.contains(10) {
            events.append(.init(packet: packet, start: start, end: end))
        } else {
            for line in packet.split(separator: "\n", maxSplits: 30_000) {
                events.append(.init(packet: String(line), start: start, end: end))
            }
        }
    }
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
        let images: [SubtitleImage]
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
            if movedBackward { context.regionLayout = .init() }
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
        guard changed != 0 else { return Frame(changed: false, images: []) }
        return Frame(changed: true, images: try context.composite(images))
    }

    private final class Context {
        let library: OpaquePointer
        let renderer: OpaquePointer
        let track: UnsafeMutablePointer<ASS_Track>
        let size: CGSize
        var regionLayout = ASSSubtitleRegionLayout()

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
            guard abs(event.start) < Double(Int64.max) / 2_000,
                  event.end - event.start < Double(Int64.max) / 2_000 else {
                throw ASSSubtitleRenderError.invalidBitmap
            }
            var packets: [ASSSubtitleEvent] = []
            ASSSubtitleEvent.appendPackets(event.packet, start: event.start, end: event.end, to: &packets)
            for event in packets {
                guard event.packet.utf8.count < 1_000_000 else { throw ASSSubtitleRenderError.invalidBitmap }
                guard track.pointee.n_events < 30_000 else { throw ASSSubtitleRenderError.allocation }
                var packet = Array(event.packet.utf8CString)
                let count = packet.count - 1
                packet.withUnsafeMutableBufferPointer {
                    ass_process_chunk(track, $0.baseAddress, Int32(count),
                                      Int64((event.start * 1_000).rounded()), Int64(((event.end - event.start) * 1_000).rounded()))
                }
            }
        }

        func composite(_ first: UnsafeMutablePointer<ASS_Image>?) throws -> [SubtitleImage] {
            let canvas = CGRect(origin: .zero, size: size)
            var layers: [ASS_Image] = []
            var rectangles: [CGRect] = []
            var pointer = first
            while let image = pointer?.pointee {
                if image.w > 0, image.h > 0 {
                    let bounds = CGRect(x: Int(image.dst_x), y: Int(image.dst_y),
                                        width: Int(image.w), height: Int(image.h)).intersection(canvas)
                    if !bounds.isNull, !bounds.isEmpty {
                        layers.append(image)
                        rectangles.append(bounds)
                    }
                }
                pointer = image.next
            }
            return try regionLayout.regions(for: rectangles, canvas: size).map {
                try composite(layers, region: $0)
            }
        }

        private func composite(_ layers: [ASS_Image], region: ASSSubtitleRegionLayout.Region) throws -> SubtitleImage {
            let bounds = region.bounds.integral
            guard let context = CGContext(
                data: nil, width: Int(bounds.width), height: Int(bounds.height),
                bitsPerComponent: 8, bytesPerRow: Int(bounds.width) * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ), let output = context.data?.assumingMemoryBound(to: UInt8.self) else {
                throw ASSSubtitleRenderError.allocation
            }
            for index in region.indices {
                let image = layers[index]
                let rect = CGRect(x: Int(image.dst_x), y: Int(image.dst_y), width: Int(image.w), height: Int(image.h))
                guard let bitmap = image.bitmap, image.stride >= image.w,
                      image.w <= 16_384, image.h <= 16_384,
                      Int64(image.stride) * Int64(image.h) <= 64 * 1_024 * 1_024 else {
                    throw ASSSubtitleRenderError.invalidBitmap
                }
                let clipped = rect.intersection(bounds)
                guard !clipped.isEmpty, !clipped.isNull else { continue }
                let maskOffset = Int(clipped.minY - rect.minY) * Int(image.stride)
                    + Int(clipped.minX - rect.minX)
                let outputOffset = Int(clipped.minY - bounds.minY) * context.bytesPerRow
                    + Int(clipped.minX - bounds.minX) * 4
                plozz_ass_blend_bitmap(
                    output.advanced(by: outputOffset), context.bytesPerRow,
                    bitmap.advanced(by: maskOffset), Int(image.stride),
                    Int(clipped.width), Int(clipped.height), image.color
                )
            }
            guard let image = context.makeImage() else { throw ASSSubtitleRenderError.allocation }
            return SubtitleImage(cgImage: image,
                                 normalizedRect: CGRect(x: bounds.minX / size.width, y: bounds.minY / size.height,
                                                        width: bounds.width / size.width, height: bounds.height / size.height),
                                 canvasSize: size, controlAvoidance: region.avoidance)
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
    private var requestedTime: Double?
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
        guard !failed, document != nil, time.isFinite else { return }
        requestedTime = time
        renderPendingFrame()
    }

    private func renderPendingFrame() {
        // The display link owns cadence. A hard 1/60 cutoff skips alternating
        // ticks on 59.94 Hz displays; libass itself uses millisecond timestamps.
        guard pending == nil, let document, let time = requestedTime,
              lastTime.map({ abs(time - $0) >= 0.001 }) ?? true else { return }
        requestedTime = nil
        lastTime = time
        let revision = revision, events = events, rasterizer = rasterizer
        pending = Task { [weak self] in
            do {
                let frame = try await rasterizer.render(document: document, events: events, time: time)
                guard let self, !Task.isCancelled, self.revision == revision else { return }
                pending = nil
                defer { renderPendingFrame() }
                guard frame.changed else { return }
                onFrame?(frame.images.map {
                    frameID &+= 1
                    return SubtitleCue(id: frameID, start: 0, end: .greatestFiniteMagnitude, body: .image($0))
                })
            } catch {
                guard let self, !Task.isCancelled, self.revision == revision else { return }
                pending = nil
                requestedTime = nil
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
        requestedTime = nil
        document = nil
        events = []
        lastTime = nil
        failed = false
        rasterizer = ASSSubtitleRasterizer()
        onFrame?([])
    }
}
