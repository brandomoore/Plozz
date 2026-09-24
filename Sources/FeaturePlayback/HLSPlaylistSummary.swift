import Foundation

/// What an HLS playlist offers, read from its tags — for the live player's Stats
/// tab. Parsing only: nothing here fetches, selects, or plays anything.
///
/// A media playlist (segments, no `EXT-X-STREAM-INF`) is a single-variant
/// stream; only a master playlist has variants and renditions to list.
public struct HLSPlaylistSummary: Equatable, Sendable {
    public struct Variant: Equatable, Hashable, Sendable {
        public var bandwidth: Int
        public var averageBandwidth: Int?
        public var resolution: String?
        public var frameRate: Double?
        public var codecs: [String]
        public var audioGroup: String?
        public var subtitleGroup: String?
        public var uri: String
    }

    public struct Rendition: Equatable, Hashable, Sendable {
        public enum Kind: String, Sendable { case audio = "AUDIO", subtitles = "SUBTITLES", closedCaptions = "CLOSED-CAPTIONS" }
        public var kind: Kind
        public var groupID: String?
        public var name: String?
        public var language: String?
        public var channels: String?
        public var isDefault: Bool
    }

    public var isMaster: Bool
    public var variants: [Variant]
    public var renditions: [Rendition]

    public init(playlist text: String) {
        var variants: [Variant] = []
        var renditions: [Rendition] = []
        var pending: [String: String]?
        var sawSegment = false
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                pending = Self.attributes(String(line.dropFirst("#EXT-X-STREAM-INF:".count)))
            } else if line.hasPrefix("#EXT-X-MEDIA:") {
                let attributes = Self.attributes(String(line.dropFirst("#EXT-X-MEDIA:".count)))
                guard let type = attributes["TYPE"].flatMap(Rendition.Kind.init(rawValue:)) else { continue }
                renditions.append(Rendition(
                    kind: type, groupID: attributes["GROUP-ID"], name: attributes["NAME"],
                    language: attributes["LANGUAGE"], channels: attributes["CHANNELS"],
                    isDefault: attributes["DEFAULT"] == "YES"
                ))
            } else if line.hasPrefix("#EXTINF") {
                sawSegment = true
            } else if !line.hasPrefix("#"), let attributes = pending {
                pending = nil
                variants.append(Variant(
                    bandwidth: attributes["BANDWIDTH"].flatMap(Int.init) ?? 0,
                    averageBandwidth: attributes["AVERAGE-BANDWIDTH"].flatMap(Int.init),
                    resolution: attributes["RESOLUTION"],
                    frameRate: attributes["FRAME-RATE"].flatMap(Double.init),
                    codecs: attributes["CODECS"].map {
                        $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                    } ?? [],
                    audioGroup: attributes["AUDIO"],
                    subtitleGroup: attributes["SUBTITLES"],
                    uri: line
                ))
            }
        }
        self.isMaster = !variants.isEmpty && !sawSegment
        self.variants = variants
        self.renditions = renditions
    }

    /// One row per distinct picture on offer; variants that differ only in URI
    /// (redundant CDNs, audio-group copies) collapse into one.
    public var uniqueVideoVariants: [Variant] {
        var seen = Set<VideoKey>()
        return variants
            .filter { seen.insert(VideoKey($0)).inserted }
            .sorted { $0.bandwidth > $1.bandwidth }
    }

    public var uniqueAudioRenditions: [Rendition] { unique(renditions.filter { $0.kind == .audio }) }

    public var uniqueSubtitleRenditions: [Rendition] {
        unique(renditions.filter { $0.kind == .subtitles || $0.kind == .closedCaptions })
    }

    /// Audio codecs muxed into the variants themselves, for masters that declare
    /// no separate audio renditions.
    public var muxedAudioCodecs: [String] {
        var seen = Set<String>()
        return variants.flatMap(\.codecs).filter(Self.isAudioCodec).filter { seen.insert($0).inserted }
    }

    public static func isAudioCodec(_ codec: String) -> Bool {
        ["mp4a", "ac-3", "ec-3", "opus", "flac", "alac", "mp3", "dts", "ac-4"].contains {
            codec.lowercased().hasPrefix($0)
        }
    }

    /// The variant whose bandwidth is nearest `bitrate`.
    public func variant(nearestBandwidth bitrate: Double) -> Variant? {
        guard bitrate > 0 else { return nil }
        return variants.min { abs(Double($0.bandwidth) - bitrate) < abs(Double($1.bandwidth) - bitrate) }
    }

    private struct VideoKey: Hashable {
        let bandwidth: Int
        let resolution: String?
        let frameRate: Double?
        let codecs: [String]
        init(_ variant: Variant) {
            bandwidth = variant.bandwidth
            resolution = variant.resolution
            frameRate = variant.frameRate
            codecs = variant.codecs
        }
    }

    private func unique(_ renditions: [Rendition]) -> [Rendition] {
        var seen = Set<[String?]>()
        return renditions.filter { seen.insert([$0.kind.rawValue, $0.name, $0.language, $0.channels]).inserted }
    }

    /// `KEY=VALUE` pairs, with quoted values allowed to contain commas.
    static func attributes(_ list: String) -> [String: String] {
        var result: [String: String] = [:]
        var key = ""
        var value = ""
        var readingKey = true
        var quoted = false
        func commit() {
            let name = key.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { result[name] = value }
            key = ""
            value = ""
            readingKey = true
        }
        for character in list {
            if readingKey {
                if character == "=" { readingKey = false } else { key.append(character) }
            } else if character == "\"" {
                quoted.toggle()
            } else if character == ",", !quoted {
                commit()
            } else {
                value.append(character)
            }
        }
        commit()
        return result
    }
}
