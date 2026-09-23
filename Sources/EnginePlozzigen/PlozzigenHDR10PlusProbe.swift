import Foundation
import AetherEngine

/// Positive-only compatibility entry point. Parsing and demuxing belong to
/// AetherEngine; the adapter owns only its stricter HTTP transport.
public enum PlozzigenHDR10PlusProbe {
    public static func probe(url: URL) async -> Bool? {
        let limits = HDR10PlusProbeLimits()
        let budget = HDR10PlusProbeBudget(limits: limits)
        let source = HDR10PlusHTTPRangeSource(url: url, budget: budget)
        let probe = await PlozzigenStreamProbeExecutor.runDetailProbe(
            reader: HDR10PlusAVIOReader(source: source, budget: budget),
            requirements: .hdr10Plus,
            limits: limits,
            budget: budget
        )
        return probe?.carriesHDR10PlusMetadata == true ? true : nil
    }
}

/// A one-shot, bounded HTTP reader. Cursor access is confined to the native
/// probe queue; cancellation only touches the thread-safe budget and source.
final class HDR10PlusAVIOReader: IOReader, @unchecked Sendable {
    let source: any HDR10PlusRangeSource
    let budget: HDR10PlusProbeBudget
    private var position: Int64 = 0

    init(source: any HDR10PlusRangeSource, budget: HDR10PlusProbeBudget) {
        self.source = source
        self.budget = budget
    }

    var discImageProbeEnabled: Bool { false }

    func read(_ buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 {
        guard let buffer, size > 0, budget.isActive else { return -1 }
        guard let data = source.read(at: position, count: min(Int(size), budget.limits.rangeBytes)),
              data.count <= Int(size), budget.isActive
        else {
            // Demuxers may recover from a failed read using buffered packets.
            // Invalid HTTP must invalidate the entire result, not just this read.
            budget.cancel()
            return -1
        }
        guard !data.isEmpty else { return 0 }
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
        if whence & 65_536 != 0 { return source.size ?? -1 } // AVSEEK_SIZE
        let base: Int64
        switch whence & ~131_072 { // AVSEEK_FORCE
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

    func cancel() {
        budget.cancel()
        source.close()
    }

    func close() { source.close() }
}
