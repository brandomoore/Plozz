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
    private var earliestEnd = Double.infinity
    private var lastPruneTime = -Double.infinity
    private var snapshot: [ASSSubtitleEvent] = []
    private var snapshotRevision: Int?
    private var admittedThrough = -Double.infinity
    private var nextCueBoundary = Double.infinity
    private var lastTime: Double?

    struct Frame: Sendable {
        let changed: Bool
        let images: [SubtitleImage]
        let renderSeconds: Double
        let addedEvents: Int
        let nextCueBoundary: Double?
    }

    func render(document: ASSSubtitleDocument, events incoming: [ASSSubtitleEvent], time: Double,
                snapshotRevision revision: Int? = nil) throws -> Frame {
        let started = ProcessInfo.processInfo.systemUptime
        guard time.isFinite, abs(time) < Double(Int64.max) / 2_000 else { throw ASSSubtitleRenderError.invalidCanvas }
        if identity != document.identity {
            context = try Context(document: document)
            identity = document.identity
            events.removeAll(keepingCapacity: true)
            eventBytes = 0
            earliestEnd = .infinity
            lastPruneTime = -.infinity
            snapshot = []
            snapshotRevision = nil
            admittedThrough = -.infinity
            nextCueBoundary = .infinity
            lastTime = nil
        }
        guard let context else { throw ASSSubtitleRenderError.initialization }
        let movedBackward = lastTime.map { time < $0 - 0.1 } ?? false
        if movedBackward {
            ass_flush_events(context.track)
            context.regionLayout = .init()
            events.removeAll(keepingCapacity: true)
            eventBytes = 0
            earliestEnd = .infinity
            lastPruneTime = -.infinity
            admittedThrough = -.infinity
        } else if events.count > 1_000 && earliestEnd < time - 2 && time >= lastPruneTime + 3 {
            ass_prune_events(context.track, Int64(((time - 2) * 1_000).rounded(.down)))
            events = events.filter { $0.end >= time - 2 }
            eventBytes = events.reduce(0) { $0 + $1.packet.utf8.count }
            earliestEnd = events.map(\.end).min() ?? .infinity
            lastPruneTime = time
        }
        lastTime = time
        let changedSnapshot = revision == nil || revision != snapshotRevision
        let extendedWindow = time + 2 >= admittedThrough + 1
        let appended = changedSnapshot && incoming.count >= snapshot.count
            && incoming.prefix(snapshot.count).elementsEqual(snapshot)
        let candidates: ArraySlice<ASSSubtitleEvent>
        if movedBackward || extendedWindow || (changedSnapshot && !appended) {
            candidates = incoming[...]
        } else if changedSnapshot {
            candidates = incoming.dropFirst(snapshot.count)
        } else {
            candidates = []
        }
        if changedSnapshot {
            snapshot = incoming
            snapshotRevision = revision
        }
        if changedSnapshot || time >= nextCueBoundary {
            nextCueBoundary = .infinity
            for event in incoming where event.start.isFinite && event.end.isFinite && event.end > event.start {
                if event.start > time { nextCueBoundary = min(nextCueBoundary, event.start) }
                if event.end > time { nextCueBoundary = min(nextCueBoundary, event.end) }
            }
        }
        if extendedWindow { admittedThrough = time + 2 }
        var addedEvents = 0
        for event in candidates where event.start.isFinite && event.end.isFinite
            && event.end > event.start && event.end >= time - 2 && event.start <= time + 2 {
            guard events.insert(event).inserted else { continue }
            eventBytes += event.packet.utf8.count
            guard events.count <= 30_000, eventBytes <= 32 * 1_024 * 1_024 else {
                throw ASSSubtitleRenderError.allocation
            }
            try context.append(event)
            earliestEnd = min(earliestEnd, event.end)
            addedEvents += 1
        }
        var changed: Int32 = 0
        let images = ass_render_frame(context.renderer, context.track, Int64((time * 1_000).rounded()), &changed)
        guard changed != 0 else {
            return Frame(changed: false, images: [],
                         renderSeconds: ProcessInfo.processInfo.systemUptime - started, addedEvents: addedEvents,
                         nextCueBoundary: nextCueBoundary.isFinite ? nextCueBoundary : nil)
        }
        let composited = try context.composite(images)
        return Frame(changed: true, images: composited,
                     renderSeconds: ProcessInfo.processInfo.systemUptime - started, addedEvents: addedEvents,
                     nextCueBoundary: nextCueBoundary.isFinite ? nextCueBoundary : nil)
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

struct ASSSubtitleFramePacer {
    private var nextTime: Double?
    private var lastTime: Double?

    mutating func admit(_ time: Double, frameRate: Double?, cueBoundary: Double? = nil) -> Bool {
        let interval = 1 / min(max(frameRate.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 60, 24), 60)
        if let lastTime, time < lastTime - 0.1 {
            nextTime = nil
        }
        if let scheduled = nextTime, time < scheduled {
            guard let cueBoundary, let lastTime, lastTime < cueBoundary, time >= cueBoundary else {
                return false
            }
            nextTime = time
        }
        let next = nextTime ?? time
        // Advance from the frame slot, not the display tick, to preserve fractional video rates.
        nextTime = time - next < interval ? next + interval : time + interval
        lastTime = time
        return true
    }

    mutating func complete(renderSeconds: Double) {
        guard let lastTime, renderSeconds.isFinite else { return }
        // Leave at least 30% of the interval for the software video and audio pipelines.
        nextTime = max(nextTime ?? lastTime, lastTime + min(renderSeconds / 0.7, 0.25))
    }
}

struct ASSSubtitleRenderLead {
    private var latency = 0.0
    private var lastTick: (time: Double, uptime: Double)?
    private var playbackRate = 0.0

    mutating func tick(_ time: Double, uptime: Double) {
        if let lastTick, uptime > lastTick.uptime {
            let rate = (time - lastTick.time) / (uptime - lastTick.uptime)
            playbackRate = rate.isFinite ? min(max(rate, 0), 1.5) : 0
        }
        lastTick = (time, uptime)
    }

    mutating func complete(elapsed: Double) {
        guard elapsed.isFinite, elapsed >= 0 else { return }
        latency = latency == 0 ? elapsed : (latency + elapsed) / 2
    }

    func time(for playbackTime: Double) -> Double {
        playbackTime + min(latency * playbackRate, 0.2)
    }
}

@MainActor
final class ASSSubtitleRenderer {
    private var rasterizer = ASSSubtitleRasterizer()
    private var document: ASSSubtitleDocument?
    private var events: [ASSSubtitleEvent] = []
    private var eventSnapshotRevision = 0
    private var revision = 0
    private var frameID = 0
    private var pending: Task<Void, Never>?
    private var requestedTime: Double?
    private var lastTime: Double?
    private var frameRate: Double?
    private var nextCueBoundary: Double?
    private var pacer = ASSSubtitleFramePacer()
    private var renderLead = ASSSubtitleRenderLead()
    private var failed = false
    var onFrame: (([SubtitleCue]) -> Void)?

    func update(document: ASSSubtitleDocument, events: [ASSSubtitleEvent]) {
        if self.document?.identity != document.identity || events.isEmpty { clear() }
        self.document = document
        self.events = events
        eventSnapshotRevision &+= 1
        lastTime = nil
    }

    func tick(_ time: Double, frameRate: Double? = nil) {
        guard !failed, document != nil, time.isFinite else { return }
        renderLead.tick(time, uptime: ProcessInfo.processInfo.systemUptime)
        requestedTime = time
        self.frameRate = frameRate
        renderPendingFrame()
    }

    private func renderPendingFrame() {
        // The display link owns cadence. A hard 1/60 cutoff skips alternating
        // ticks on 59.94 Hz displays; libass itself uses millisecond timestamps.
        guard pending == nil, let document, let time = requestedTime,
              lastTime.map({ abs(time - $0) >= 0.001 }) ?? true else { return }
        guard pacer.admit(time, frameRate: frameRate, cueBoundary: nextCueBoundary) else { return }
        requestedTime = nil
        lastTime = time
        let revision = revision, events = events, eventSnapshotRevision = eventSnapshotRevision, rasterizer = rasterizer
        let renderTime = renderLead.time(for: time)
        let started = ProcessInfo.processInfo.systemUptime
        pending = Task(priority: .userInitiated) { [weak self] in
            do {
                let frame = try await rasterizer.render(document: document, events: events, time: renderTime,
                                                        snapshotRevision: eventSnapshotRevision)
                guard let self, !Task.isCancelled, self.revision == revision else { return }
                pending = nil
                renderLead.complete(elapsed: ProcessInfo.processInfo.systemUptime - started)
                pacer.complete(renderSeconds: frame.renderSeconds)
                nextCueBoundary = frame.nextCueBoundary
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
        frameRate = nil
        nextCueBoundary = nil
        pacer = ASSSubtitleFramePacer()
        renderLead = ASSSubtitleRenderLead()
        failed = false
        rasterizer = ASSSubtitleRasterizer()
        onFrame?([])
    }
}
