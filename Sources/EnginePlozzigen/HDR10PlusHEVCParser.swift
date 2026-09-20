import Foundation

/// Packet framing and SEI parsing only. The caller validates the ST 2094-40
/// payload before treating a registered T.35 message as positive evidence.
enum HDR10PlusHEVCParser {
    static func containsHDR10Plus(
        in packet: Data,
        configuration: Data?,
        isActive: () -> Bool = { true },
        validate: (Data) -> Bool
    ) -> Bool {
        let bytes = [UInt8](packet)
        let ranges: [Range<Int>]
        if let configuration, configuration.first == 1 {
            guard validConfiguration(configuration, isActive: isActive) else { return false }
            let width = Int(configuration[configuration.startIndex + 21] & 3) + 1
            guard let parsed = lengthPrefixedRanges(bytes, width: width, isActive: isActive) else {
                return false
            }
            ranges = parsed
        } else {
            guard let parsed = annexBRanges(bytes, isActive: isActive) else { return false }
            ranges = parsed
        }

        var found = false
        for range in ranges {
            guard isActive(), range.count >= 2 else { return false }
            let first = bytes[range.lowerBound]
            let second = bytes[range.lowerBound + 1]
            guard first & 0x80 == 0, second & 7 != 0 else { return false }
            let type = (first >> 1) & 0x3f
            guard type == 39 || type == 40 else { continue }
            guard let rbsp = unescapedRBSP(bytes[(range.lowerBound + 2)..<range.upperBound]),
                  let messages = registeredMessages(rbsp)
            else { return false }
            for message in messages {
                guard isActive() else { return false }
                // Country B5, provider 003C, provider-oriented 0001,
                // application 4; versions 0 and 1 are the known HDR10+ syntax.
                guard message.count > 7,
                      message.prefix(6).elementsEqual([0xb5, 0, 0x3c, 0, 1, 4]),
                      message[6] <= 1
                else { continue }
                if validate(Data(message.dropFirst(6))) { found = true }
            }
        }
        return found && isActive()
    }

    private static func validConfiguration(_ data: Data, isActive: () -> Bool) -> Bool {
        let bytes = [UInt8](data)
        guard bytes.count >= 23 else { return false }
        var offset = 23
        for _ in 0..<Int(bytes[22]) {
            guard isActive(), bytes.count - offset >= 3 else { return false }
            let count = (Int(bytes[offset + 1]) << 8) | Int(bytes[offset + 2])
            offset += 3
            for _ in 0..<count {
                guard isActive(), bytes.count - offset >= 2 else { return false }
                let length = (Int(bytes[offset]) << 8) | Int(bytes[offset + 1])
                offset += 2
                guard length >= 2, length <= bytes.count - offset else { return false }
                offset += length
            }
        }
        return offset == bytes.count
    }

    private static func lengthPrefixedRanges(
        _ bytes: [UInt8], width: Int, isActive: () -> Bool
    ) -> [Range<Int>]? {
        var ranges: [Range<Int>] = []
        var offset = 0
        while offset < bytes.count {
            guard isActive(), ranges.count < 4096, bytes.count - offset >= width else { return nil }
            var length = 0
            for index in offset..<(offset + width) {
                length = (length << 8) | Int(bytes[index])
            }
            offset += width
            guard length >= 2, length <= bytes.count - offset else { return nil }
            ranges.append(offset..<(offset + length))
            offset += length
        }
        return ranges.isEmpty ? nil : ranges
    }

    private static func annexBRanges(
        _ bytes: [UInt8], isActive: () -> Bool
    ) -> [Range<Int>]? {
        var ranges: [Range<Int>] = []
        var start: Int?
        var zeros = 0
        for index in bytes.indices {
            if index & 0x3fff == 0, !isActive() { return nil }
            if bytes[index] == 0 {
                zeros += 1
            } else {
                if bytes[index] == 1, zeros >= 2 {
                    if let start {
                        guard index - zeros - start >= 2, ranges.count < 4096 else { return nil }
                        ranges.append(start..<(index - zeros))
                    } else if index != zeros {
                        return nil
                    }
                    start = index + 1
                }
                zeros = 0
            }
        }
        guard let start, bytes.count - zeros - start >= 2, ranges.count < 4096 else { return nil }
        ranges.append(start..<(bytes.count - zeros))
        return ranges
    }

    private static func unescapedRBSP(_ bytes: ArraySlice<UInt8>) -> [UInt8]? {
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        var zeros = 0
        var offset = bytes.startIndex
        while offset < bytes.endIndex {
            let byte = bytes[offset]
            if zeros >= 2 {
                if byte == 3 {
                    guard offset + 1 < bytes.endIndex, bytes[offset + 1] <= 3 else { return nil }
                    zeros = 0
                    offset += 1
                    continue
                }
                guard byte > 2 else { return nil }
            }
            output.append(byte)
            zeros = byte == 0 ? zeros + 1 : 0
            offset += 1
        }
        return output
    }

    private static func registeredMessages(_ rbsp: [UInt8]) -> [[UInt8]]? {
        var messages: [[UInt8]] = []
        var offset = 0
        var messageCount = 0
        while offset < rbsp.count {
            if offset == rbsp.count - 1, rbsp[offset] == 0x80 { return messages }
            messageCount += 1
            guard messageCount <= 4096,
                  let type = extendedValue(rbsp, offset: &offset),
                  let size = extendedValue(rbsp, offset: &offset),
                  size <= rbsp.count - offset
            else { return nil }
            // ST 2094-40 has a maximum 907-byte body, plus the six T.35
            // registration bytes. Do not retain arbitrary user-data payloads.
            if type == 4, size <= 913 {
                messages.append(Array(rbsp[offset..<(offset + size)]))
            }
            offset += size
        }
        return nil // rbsp_trailing_bits is mandatory.
    }

    private static func extendedValue(_ bytes: [UInt8], offset: inout Int) -> Int? {
        var result = 0
        while offset < bytes.count {
            let byte = Int(bytes[offset])
            offset += 1
            let (next, overflow) = result.addingReportingOverflow(byte)
            guard !overflow else { return nil }
            result = next
            if byte != 255 { return result }
        }
        return nil
    }
}
