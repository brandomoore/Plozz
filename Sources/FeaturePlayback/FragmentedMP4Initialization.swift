import Foundation

enum FragmentedMP4Initialization {
    private struct Box {
        let type: String
        let header: Data
        let payload: Data

        func replacingPayload(_ data: Data) -> Data {
            guard data != payload else { return header + payload }
            var result = header
            let size = UInt64(header.count + data.count)
            if header.count == 16 {
                for index in 0..<8 { result[8 + index] = UInt8(truncatingIfNeeded: size >> (56 - index * 8)) }
            } else if header.prefix(4) != Data(repeating: 0, count: 4) {
                for index in 0..<4 { result[index] = UInt8(truncatingIfNeeded: size >> (24 - index * 8)) }
            }
            result.append(data)
            return result
        }
    }

    /// Emby's HEVC muxer can write an empty `sdtp` in an empty fragmented
    /// sample table. AVFoundation rejects that box before decoding any samples.
    static func removingEmptySampleDependencies(from data: Data) throws -> Data? {
        guard data.count <= 1_048_576 else { throw URLError(.dataLengthExceedsMaximum) }
        let root = try boxes(in: data)
        guard root.contains(where: { $0.type == "ftyp" }),
              let movie = root.first(where: { $0.type == "moov" }),
              try boxes(in: movie.payload).contains(where: { $0.type == "mvex" }) else { return nil }
        var changed = false
        let result = try rewrite(data, container: "", changed: &changed)
        return changed ? result : nil
    }

    private static func rewrite(_ data: Data, container: String, changed: inout Bool) throws -> Data {
        let children = try boxes(in: data)
        let sizes = children.filter { $0.type == "stsz" }
        let hasNoSamples = container == "stbl" && sizes.count == 1
            && sizes[0].payload.count == 12 && sizes[0].payload.allSatisfy { $0 == 0 }
        let next = ["": "moov", "moov": "trak", "trak": "mdia", "mdia": "minf", "minf": "stbl"][container]
        var result = Data()
        for box in children {
            if hasNoSamples, box.type == "sdtp", box.payload == Data(repeating: 0, count: 4) {
                changed = true
                continue
            }
            if box.type == next {
                result.append(box.replacingPayload(try rewrite(box.payload, container: box.type, changed: &changed)))
            } else {
                result.append(box.header)
                result.append(box.payload)
            }
        }
        return result
    }

    private static func boxes(in data: Data) throws -> [Box] {
        let bytes = [UInt8](data)
        var result: [Box] = []
        var offset = 0
        while offset < bytes.count {
            guard bytes.count - offset >= 8 else { throw URLError(.cannotParseResponse) }
            func integer(_ start: Int, _ count: Int) -> UInt64 {
                bytes[start..<start + count].reduce(0) { ($0 << 8) | UInt64($1) }
            }
            let shortSize = integer(offset, 4)
            let headerSize = shortSize == 1 ? 16 : 8
            guard bytes.count - offset >= headerSize else { throw URLError(.cannotParseResponse) }
            let size = shortSize == 1 ? integer(offset + 8, 8)
                : shortSize == 0 ? UInt64(bytes.count - offset) : shortSize
            guard size >= UInt64(headerSize), size <= UInt64(bytes.count - offset) else {
                throw URLError(.cannotParseResponse)
            }
            let end = offset + Int(size)
            result.append(Box(
                type: String(decoding: bytes[offset + 4..<offset + 8], as: UTF8.self),
                header: Data(bytes[offset..<offset + headerSize]),
                payload: Data(bytes[offset + headerSize..<end])
            ))
            offset = end
        }
        return result
    }
}
