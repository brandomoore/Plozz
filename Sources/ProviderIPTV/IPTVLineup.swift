import Foundation

/// The live-lineup fields the channel list and guide matching need, in catalogue order.
/// Reading them from one saved blob avoids opening and decoding every sealed record.
struct IPTVLineupEntry: Equatable, Sendable {
    var id: String
    var title: String
    var channelNumber: Int?
    var posterURL: URL?
    var tags: [String]
    var guideID: String?
    var guideName: String?
    var guideCountry: String?

    init(_ record: IPTVRecord) {
        id = record.item.id
        title = record.item.title
        channelNumber = record.channelNumber
        posterURL = record.item.posterURL
        tags = record.item.tags
        guideID = record.guideID
        guideName = record.guideName
        guideCountry = record.guideCountry
    }

    private init(
        id: String, title: String, channelNumber: Int?, posterURL: URL?, tags: [String],
        guideID: String?, guideName: String?, guideCountry: String?
    ) {
        self.id = id
        self.title = title
        self.channelNumber = channelNumber
        self.posterURL = posterURL
        self.tags = tags
        self.guideID = guideID
        self.guideName = guideName
        self.guideCountry = guideCountry
    }

    private static let version: UInt8 = 1
    private static let absent = UInt32.max

    /// Length-prefixed UTF-8 fields; `nil` when a lineup cannot be represented.
    static func encode(_ entries: [IPTVLineupEntry]) -> Data? {
        guard entries.count < Int(absent) else { return nil }
        var bytes: [UInt8] = [version]
        bytes.reserveCapacity(entries.count * 128)
        func append(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) } }
        func append(_ text: String?) -> Bool {
            guard let text else { append(absent); return true }
            let utf8 = text.utf8
            guard utf8.count < Int(absent) else { return false }
            append(UInt32(utf8.count))
            bytes.append(contentsOf: utf8)
            return true
        }
        append(UInt32(entries.count))
        for entry in entries {
            guard entry.tags.count < Int(absent), append(entry.id), append(entry.title),
                  append(entry.channelNumber.map(String.init)), append(entry.posterURL?.absoluteString),
                  append(entry.guideID), append(entry.guideName), append(entry.guideCountry) else { return nil }
            append(UInt32(entry.tags.count))
            for tag in entry.tags { guard append(tag) else { return nil } }
        }
        return Data(bytes)
    }

    /// `nil` for anything that is not a complete lineup written by `encode`.
    static func decode(_ data: Data) -> [IPTVLineupEntry]? {
        data.withUnsafeBytes { buffer -> [IPTVLineupEntry]? in
            var offset = 0
            func integer() -> UInt32? {
                guard buffer.count - offset >= 4 else { return nil }
                defer { offset += 4 }
                return UInt32(littleEndian: buffer.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
            }
            // Outer optional: malformed. Inner optional: an absent field.
            func text() -> String?? {
                guard let length = integer() else { return nil }
                if length == absent { return .some(nil) }
                guard buffer.count - offset >= Int(length) else { return nil }
                defer { offset += Int(length) }
                let slice = UnsafeRawBufferPointer(rebasing: buffer[offset..<offset + Int(length)])
                return .some(String(decoding: slice, as: UTF8.self))
            }
            guard buffer.first == version else { return nil }
            offset = 1
            guard let count = integer() else { return nil }
            var entries: [IPTVLineupEntry] = []
            // Every entry needs at least its eight length prefixes.
            guard Int(count) <= (buffer.count - offset) / 32 else { return nil }
            entries.reserveCapacity(Int(count))
            for _ in 0..<count {
                guard case .some(.some(let id)) = text(), case .some(.some(let title)) = text(),
                      let number = text(), let poster = text(), let guideID = text(),
                      let guideName = text(), let guideCountry = text(), let tagCount = integer(),
                      Int(tagCount) <= (buffer.count - offset) / 4 else { return nil }
                var tags: [String] = []
                tags.reserveCapacity(Int(tagCount))
                for _ in 0..<tagCount {
                    guard case .some(.some(let tag)) = text() else { return nil }
                    tags.append(tag)
                }
                var channelNumber: Int?
                if let number {
                    guard let value = Int(number) else { return nil }
                    channelNumber = value
                }
                var posterURL: URL?
                if let poster {
                    guard let value = URL(string: poster) else { return nil }
                    posterURL = value
                }
                entries.append(IPTVLineupEntry(
                    id: id, title: title, channelNumber: channelNumber, posterURL: posterURL, tags: tags,
                    guideID: guideID, guideName: guideName, guideCountry: guideCountry
                ))
            }
            return offset == buffer.count ? entries : nil
        }
    }
}
