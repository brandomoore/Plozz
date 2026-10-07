import Foundation

/// Xtream list endpoints are unpaged JSON arrays. Retain one object, not the
/// entire response; punctuation inside quoted strings never changes nesting.
struct IPTVJSONArrayStream {
    private var started = false
    private var ended = false
    private var expectsValue = true
    private var hasValue = false
    private var depth = 0
    private var quoted = false
    private var escaped = false
    private var record = Data()
    private let maximumRecordBytes = 8 * 1_024 * 1_024

    mutating func append(_ data: Data, consume: (Data) throws -> Void) throws {
        for byte in data {
            if depth == 0 {
                if [9, 10, 13, 32].contains(byte) { continue }
                guard !ended else { throw IPTVError.malformed }
                if !started {
                    guard byte == 91 else { throw IPTVError.unsupported }
                    started = true
                } else if byte == 93 {
                    guard !expectsValue || !hasValue else { throw IPTVError.malformed }
                    ended = true
                } else if byte == 44 {
                    guard !expectsValue else { throw IPTVError.malformed }
                    expectsValue = true
                } else {
                    guard expectsValue, byte == 123 else { throw IPTVError.malformed }
                    record.append(byte)
                    depth = 1
                    quoted = false
                    escaped = false
                }
                continue
            }
            guard record.count < maximumRecordBytes else { throw IPTVError.oversizedRecord }
            record.append(byte)
            if quoted {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { quoted = false }
            } else if byte == 34 { quoted = true }
            else if byte == 123 || byte == 91 { depth += 1 }
            else if byte == 125 || byte == 93 {
                depth -= 1
                if depth == 0 {
                    try consume(record)
                    record.removeAll(keepingCapacity: true)
                    expectsValue = false
                    hasValue = true
                }
            }
        }
    }

    func finish() throws {
        guard started, ended, depth == 0 else { throw IPTVError.malformed }
    }
}
