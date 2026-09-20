import Foundation
import AetherLibavformat
import AetherLibavcodec
import AetherLibavutil

/// Positive-only, bounded detail enrichment; never an absence test or playback
/// prerequisite. The caller supplies a freshly resolved, authenticated URL.
public enum PlozzigenHDR10PlusProbe {
    public static func probe(url: URL) async -> Bool? {
        await HDR10PlusProbeExecutor.run { budget in
            let source = HDR10PlusHTTPRangeSource(url: url, budget: budget)
            return inspect(source: source, budget: budget)
        }
    }

    static func inspect(source: any HDR10PlusRangeSource, budget: HDR10PlusProbeBudget) -> Bool? {
        defer { source.close() }
        guard budget.isActive else { return nil }
        budget.onCancellation { [weak source] in source?.close() }
        let reader = HDR10PlusAVIOReader(source: source, budget: budget)
        let opaque = Unmanaged.passRetained(reader).toOpaque()
        defer { Unmanaged<HDR10PlusAVIOReader>.fromOpaque(opaque).release() }

        let bufferSize = 32 * 1024
        guard let allocation = av_malloc(bufferSize) else { return nil }
        var io = avio_alloc_context(
            allocation.assumingMemoryBound(to: UInt8.self), Int32(bufferSize), 0, opaque,
            { opaque, buffer, count in
                guard let opaque, let buffer else { return -1 }
                return Unmanaged<HDR10PlusAVIOReader>.fromOpaque(opaque).takeUnretainedValue()
                    .read(into: buffer, count: count)
            },
            nil,
            { opaque, offset, whence in
                guard let opaque else { return -1 }
                return Unmanaged<HDR10PlusAVIOReader>.fromOpaque(opaque).takeUnretainedValue()
                    .seek(offset: offset, whence: whence)
            }
        )
        guard let ioContext = io else {
            av_free(allocation)
            return nil
        }
        defer {
            // avformat may replace the original buffer during probing.
            av_free(ioContext.pointee.buffer)
            ioContext.pointee.buffer = nil
            avio_context_free(&io)
        }
        var context = avformat_alloc_context()
        guard let allocated = context else { return nil }
        allocated.pointee.pb = ioContext
        allocated.pointee.flags |= AVFMT_FLAG_CUSTOM_IO
        allocated.pointee.probesize = Int64(min(budget.limits.networkBytes, 1024 * 1024))
        allocated.pointee.max_probe_packets = Int32(min(budget.limits.packets, Int(Int32.max)))
        allocated.pointee.interrupt_callback = AVIOInterruptCB(
            callback: { opaque in
                guard let opaque else { return 1 }
                return Unmanaged<HDR10PlusAVIOReader>.fromOpaque(opaque).takeUnretainedValue()
                    .budget.isActive ? 0 : 1
            },
            opaque: opaque
        )
        // No FFmpeg URL protocols or secondary I/O, including container-provided
        // external references. Only the already-bounded custom AVIO can read.
        allocated.pointee.io_open = { _, _, _, _, _ in -13 }
        var options: OpaquePointer?
        av_dict_set(&options, "protocol_whitelist", "", 0)
        av_dict_set(&options, "format_whitelist", "matroska,webm,mov,mp4,m4a,3gp,3g2,mj2,mpegts,hevc", 0)
        defer { av_dict_free(&options) }
        defer { avformat_close_input(&context) }
        guard avformat_open_input(&context, nil, nil, &options) >= 0,
              let context, budget.isActive
        else { return nil }

        // Container headers already identify HEVC; find_stream_info would do an
        // additional opaque packet/decode pass outside our explicit packet cap.
        var packet = av_packet_alloc()
        guard let allocatedPacket = packet else { return nil }
        defer { av_packet_free(&packet) }
        for _ in 0..<budget.limits.packets {
            guard budget.isActive, av_read_frame(context, allocatedPacket) >= 0 else { return nil }
            let confirmed = inspectPacket(allocatedPacket.pointee, context: context, budget: budget)
            av_packet_unref(allocatedPacket)
            if confirmed { return budget.isActive ? true : nil }
        }
        return nil
    }

    private static func inspectPacket(
        _ packet: AVPacket, context: UnsafeMutablePointer<AVFormatContext>, budget: HDR10PlusProbeBudget
    ) -> Bool {
        guard packet.stream_index >= 0,
              UInt32(packet.stream_index) < context.pointee.nb_streams,
              let stream = context.pointee.streams[Int(packet.stream_index)],
              stream.pointee.disposition & AV_DISPOSITION_ATTACHED_PIC == 0,
              let codec = stream.pointee.codecpar,
              codec.pointee.codec_type == AVMEDIA_TYPE_VIDEO,
              codec.pointee.codec_id == AV_CODEC_ID_HEVC,
              packet.flags & AV_PKT_FLAG_CORRUPT == 0,
              packet.size > 0, Int(packet.size) <= budget.limits.packetBytes,
              let data = packet.data
        else { return false }
        var configuration: Data?
        if codec.pointee.extradata_size > 0 {
            guard codec.pointee.extradata_size <= 1024 * 1024, let extra = codec.pointee.extradata else {
                return false
            }
            configuration = Data(bytes: extra, count: Int(codec.pointee.extradata_size))
        }
        return HDR10PlusHEVCParser.containsHDR10Plus(
            in: Data(bytes: data, count: Int(packet.size)),
            configuration: configuration,
            isActive: { budget.isActive },
            validate: validateMetadata
        )
    }

    static func validateMetadata(_ payload: Data) -> Bool {
        guard let metadata = av_dynamic_hdr_plus_alloc(nil) else { return false }
        defer { av_free(metadata) }
        return payload.withUnsafeBytes {
            av_dynamic_hdr_plus_from_t35(
                metadata, $0.baseAddress?.assumingMemoryBound(to: UInt8.self), payload.count
            ) >= 0
        }
    }
}

final class HDR10PlusAVIOReader {
    let source: any HDR10PlusRangeSource
    let budget: HDR10PlusProbeBudget
    private var position: Int64 = 0

    init(source: any HDR10PlusRangeSource, budget: HDR10PlusProbeBudget) {
        self.source = source
        self.budget = budget
    }

    func read(into buffer: UnsafeMutablePointer<UInt8>, count: Int32) -> Int32 {
        guard count > 0, budget.isActive else { return -1 }
        guard let data = source.read(at: position, count: min(Int(count), budget.limits.rangeBytes)),
              data.count <= Int(count), budget.isActive
        else {
            // Demuxers can recover from an I/O error using already-buffered
            // packets. A failed/invalid HTTP range still invalidates this probe.
            budget.cancel()
            return -1
        }
        guard !data.isEmpty else { return -541_478_725 } // AVERROR_EOF
        let (next, overflow) = position.addingReportingOverflow(Int64(data.count))
        guard !overflow else {
            budget.cancel()
            return -1
        }
        data.copyBytes(to: buffer, count: data.count)
        position = next
        return Int32(data.count)
    }

    func seek(offset: Int64, whence: Int32) -> Int64 {
        guard budget.isActive else { return -1 }
        if whence & AVSEEK_SIZE != 0 { return source.size ?? -1 }
        let base: Int64
        switch whence & ~AVSEEK_FORCE {
        case SEEK_SET: base = 0
        case SEEK_CUR: base = position
        case SEEK_END:
            guard let size = source.size else { return -1 }
            base = size
        default: return -1
        }
        let (next, overflow) = base.addingReportingOverflow(offset)
        guard !overflow, next >= 0 else { return -1 }
        position = next
        return position
    }
}
